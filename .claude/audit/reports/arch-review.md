# Architecture Re-Audit — live-ceci (2026-08-29)

Scope: 13 modules (was 10 at the 2026-08-29 baseline audit, +3: `Tickets`, `Sessions`, `Redact`).
Plain Elixir/OTP app (Bandit + Plug.Router + WebSockAdapter). No Phoenix/Ecto/Ash conventions apply.
Confirmed fixed and NOT re-reported: the `Provider`↔`Provider.Grok` xref cycle (`mix xref cycles` → none), the `LiveSession` drift test on the `gemini_ex` internal call.

## Direct answers to the five questions

**1. Tickets vs Sessions — same module, or apart?**
Apart is correct, but not for the reason the moduledocs give ("both are admission control"). They differ in every axis that matters for a merge: `Tickets` answers "did this address make an HTTP request first" (ETS, public, TTL, keyed by an opaque token, consumed by the *router* before upgrade); `Sessions` answers "is there a free slot right now" (GenServer state, keyed by monitoring the *socket process's own pid*, released on process death). A merge would force one data structure to serve two lifetimes (request-scoped token vs. connection-scoped slot) and two consumers (`Router` vs. `Socket`). Keep them apart. See P3 below for the one real cost of keeping them apart as-is.

**2. `Socket.init/1` doing the cap-then-provider admission — right place, or the router's?**
The provider-open ordering (cap before `provider.open/1`) is correct and is in the only place that can be correct — `Sessions.join/1` must run in the process that `Sessions` monitors, and that has to be the eventual socket owner. But *where in the request lifecycle* it runs is wrong. See P2 — it runs after the WebSocket upgrade (101) has already been sent to the browser, unlike the ticket/origin checks, which reject with a plain HTTP 403 before ever upgrading. Same process, same pid, avoidable inconsistency.

**3. Is `commit_turn/1`'s Gemini no-op the same mistake as the absent `send_tool_result/3`?**
Genuinely different, not the same mistake. `send_tool_result/3` was rejected because no single signature can honestly represent both providers' handshake (Gemini: synchronous return value from a callback; Grok: two async messages sent back over the socket) — the shapes are incompatible, so a shared function would be dead weight on one side by construction. `commit_turn/1` has one shape (`session -> :ok`) that **both** providers can implement, and Gemini's own moduledoc says outright it *could* implement manual turn-ending — it declines to, for a measured latency reason (1220 ms via its own VAD vs. 985 ms manual with added false-turn risk). That's a documented policy choice inside a shape both providers share, not an incompatible shape forced into one. No action needed.

**4. Coupling/cohesion across all 13 modules.**
No cross-context reach found (no module queries another's private state; `Tools`/`Persona`/`Redact` are consumed only through their public functions; both providers call `LiveCeci.Tools.dispatch/2` and `LiveCeci.Redact.inspect/1` the same way). See P3 items for the two real but minor smells found.

**5. Is `config/runtime.exs` getting long a problem?**
No — 132 lines, but the logic is ~35 lines; the rest is the comments this codebase consistently uses to record measured tradeoffs (frame_samples, turn_detection latencies), which is the project's established documentation style, not accidental bloat. This is the correct location for `.env`-driven runtime selection. One minor coupling worth naming: see P3 (provider defaults baked into the case branches).

---

## Issues (ranked)

### P2 — Session-cap admission rejects *after* the WebSocket upgrade instead of before it
`lib/live_ceci/socket.ex:47-59`, `lib/live_ceci/router.ex:116-141`

`Router`'s `get "/ws"` handler runs in the same OS/BEAM process that becomes the `WebSock` handler after `WebSockAdapter.upgrade/4` (Bandit reuses the connection process; `websock_adapter`'s own docs describe `init/1` as running "once the WebSocket connection has been successfully negotiated" — i.e., after the 101 response). `Sessions.join/1` only needs `self()`, which is identical before and after the call to `WebSockAdapter.upgrade/4`.

Today: origin check and ticket check reject with a plain HTTP 403 before upgrading; the session cap instead upgrades first (101 Switching Protocols sent to the browser), then immediately closes with 1013 from inside `WebSock.init/1`. This is an inconsistency between two admission checks that both exist to say "you may not connect" — one is cheap and pre-protocol-switch, the other pays for a handshake it's about to undo. It also means a full websocket negotiation (and, depending on browser, a visible "connected then immediately dropped" transition) happens for a request that was always going to be refused.

Fix: call `LiveCeci.Sessions.join(conn.remote_ip)` in `Router`'s `get "/ws"` clause (after the ticket/origin checks, before `WebSockAdapter.upgrade/4`), and drop the `Sessions.join` call from `Socket.init/1`. `Process.monitor(self())`'s target pid is unaffected by the call site.

### P3 — `Tickets` and `Sessions` are conceptually paired gatekeepers with no shared vocabulary
`lib/live_ceci/tickets.ex`, `lib/live_ceci/sessions.ex`

Both exist to answer "who may reach `/ws`", both are read by `Router`/`Socket` right at the admission boundary, both log a `Logger.warning` on refusal in the same style, both read their limits from `Application.get_env(:live_ceci, ...)`. Nothing forces a merge (question 1), but nothing in the naming (`LiveCeci.Tickets`, `LiveCeci.Sessions`, both top-level, siblings of `Persona`/`Tools`) signals that they're a matched pair rather than two unrelated concerns. A future reader has to read both moduledocs in full to learn they compose. Low cost today at 2 modules; worth a namespace (`LiveCeci.Admission.Tickets` / `.Sessions`) or at minimum a cross-reference in each moduledoc if a third admission mechanism is ever added.

### P3 — Provider defaults hardcoded into `config/runtime.exs`'s branch, duplicating provider selection knowledge
`config/runtime.exs:64-74`

`LiveCeci.Provider.current/0`'s moduledoc explicitly rejects naming a specific provider module inside `lib/live_ceci/provider.ex` ("a seam that names a specific backend is the kind of wrong that stops being free the day a third provider arrives"), and moved that decision to config for exactly that reason. But `config/runtime.exs` still hardcodes `LiveCeci.Provider.Gemini` / `LiveCeci.Provider.Grok` alongside each one's default model/voice string, in a `case` keyed on `MODEL`. Adding a third provider means editing this file's branch (fine, it's config) *and* knowing that model/voice defaults belong there rather than in the provider module itself — there's no `Gemini.default_model/0` counterpart to own that knowledge. Not a boundary violation (config selecting between backends is the right layer per the moduledoc's own argument), but the per-provider defaults living in a shared file rather than each provider module is one more place a third provider's addition has to touch, and one more thing the config file has to know about a provider's internals. Low priority; only worth doing if/when a third provider is added.

### P3 — `LiveCeci.Provider.Grok` is the largest module and closest to a "does everything for one provider" shape
`lib/live_ceci/provider/grok.ex` (342 lines, vs. `Gemini` at 187)

Not yet a god-module (no 400-line threshold crossed, and the length is wire-protocol translation + measured-tradeoff comments consistent with the rest of the codebase), but it's the one module to watch: if Grok's JSON event protocol grows another few event types, this is where a split (e.g., extracting message encoding/decoding from the `WebSockex` callback module) would pay off before it's needed rather than after.

---

## Summary of ranked findings

| # | Severity | Location | Issue |
|---|----------|----------|-------|
| 1 | P2 | `socket.ex:47`, `router.ex:116` | Session-cap admission happens after the WS upgrade (101) instead of before it, unlike the ticket/origin checks |
| 2 | P3 | `tickets.ex`, `sessions.ex` | Paired admission gatekeepers with no shared namespace/vocabulary |
| 3 | P3 | `config/runtime.exs:64-74` | Per-provider default model/voice hardcoded in config rather than owned by each provider module |
| 4 | P3 | `provider/grok.ex` | Largest module (342 lines); watch for a split if the Grok event protocol grows further |
