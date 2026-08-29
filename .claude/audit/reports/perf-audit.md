# Performance Re-Audit — live-ceci (latency & backpressure on the voice hot path)

Scope: `lib/`, `priv/frontend/`. Thirty commits after the 2026-08-29 baseline audit
(80/B). Plain OTP app, no Ecto/DB — not checked, not repeated below.

Baseline for context: 985 ms (xAI, manual turn detection) / 1220 ms (Gemini, server
VAD) utterance-end to first-voice-byte, provider-dominated. Findings below are
ranked by avoidable latency/growth our own code adds on top of that.

Re-verified as genuinely fixed, not re-reported: Bandit `send_timeout: 5_000`
(`application.ex:27`); voice-frame shedding past 40 queued messages
(`socket.ex:140-152`); Grok's `send_audio` as a `WebSockex.cast`
(`provider/grok.ex:98`); the worklet's preallocated `Float32Array` + one-pass clip/RMS
(`pcm-processor.js:40,56-72`); `ws.bufferedAmount` guard + bounded `activeSources`
(`main.js:80-82,173-176`); `Tools.dispatch`'s flat `binary_part` truncation
(`tools.ex:243-252`). Also newly confirmed fixed since the last report, though not on
the "already fixed" list: `Gemini.close/1` is now guarded with a 1 s
`Task.await`/`catch :exit` (`provider/gemini.ex:91-105`), closing P3-#6 from the prior
report.

---

## P1

### 1. Gemini's mic path is still the synchronous half of the bug that was fixed for Grok
`socket.ex:104` (`handle_in`) calls `provider.send_audio/2` on the one process that
also owns downstream `handle_info`/`{:push, ...}` (`socket.ex:143-151`). For Grok this
is now `WebSockex.cast/2` — fixed, fire-and-forget (`provider/grok.ex:98`). For
Gemini it still resolves to `live_session.ex:33-37`:
`GenServer.call(session, {:send_realtime_input, ...}, 1_000)` — a **blocking** call,
unchanged since before the baseline audit, called once per ~100 ms mic frame (~10/sec).

This is the exact shape the prior audit's P1-#1 described for *both* providers; only
the Grok half was fixed (`63d9b77`). Consequence, unchanged from before: while the
call is in flight, `handle_info` cannot run, so any voice/transcript/action frame
already queued for the browser waits behind it. A single slow Gemini ACK adds up to
1 s of jitter to outbound voice — comparable to the entire 1220 ms measured budget —
on every mic frame, not just the one that stalled. `MODEL=GOOGLE` remains a fully
supported, documented backend (`config/runtime.exs:65-70`, latency comment at
`provider/gemini.ex:85-88`), so this isn't dead code — it's live exposure for anyone
running the Gemini path.

Compounding factor: when this call times out (or Gemini answers `{:error, reason}`
some other way), `socket.ex:109` logs `Redact.inspect(reason)` — `Kernel.inspect` plus
4 regexes plus N `String.replace` passes — **on the same hot path**, once per failed
frame. `Redact` is correctly off the hot path in the steady state (confirmed: every
other call site is init/close/error/unhandled-message, none per-frame), but a
degraded Gemini upstream turns "off the hot path" into "10×/sec," adding CPU work
exactly when the system is already behind.

Fix shape: mirror the Grok fix — hand the frame to a process WebSockex-style, or at
minimum move the send off the socket process (e.g., `Task.start` fire-and-forget per
frame is wrong for ordering; a small per-session forwarder process akin to what
`WebSockex` already gives Grok for free is the closer match).

---

## P2

None. Everything else inspected for the re-audit (below) is bounded at realistic
scale and off the per-frame path.

---

## P3 — verified, no action needed at current scale

### 2. `Sessions.join/1` — not a bottleneck, but worth the paper trail
`sessions.ex:64-82` is a `GenServer.call` per WebSocket **upgrade**, not per frame —
nowhere near the ~10 fps audio path. `count_for/2` (`sessions.ex:94-96`,
`Enum.count/2` over the holders map) runs at `map_size(holders) <= max_total()`,
default 8, configurable up to 1000 (`config/runtime.exs:124`). Even at 1000 this is a
single-digit-microsecond linear scan; at the default cap of 8 it's noise. The
`handle_call` body does pure map ops plus a deferred (level-gated) `Logger.warning`
on refusal — no I/O, so it essentially cannot block. If it somehow did: the call has
no explicit timeout, so a wedged `Sessions` process would stall *new* connection
attempts for up to the default 5 s before failing — existing audio streams are
unaffected, since `join/1` runs once at `init/1` and never again per socket. No fix
needed at current scale; flag only if `MAX_SESSIONS` is ever pushed toward the high
end of its configured range in a deployment that also expects fast reconnect storms.

### 3. `Tickets.issue/1` sweeping the whole table on every mint — cheap at the configured cap
`tickets.ex:60-71` calls `sweep/0` (`tickets.ex:102-105`, `:ets.select_delete/2` over
the full table) on every ticket mint, bounded by `@max_outstanding` 200
(`tickets.ex:46`). A full-table `select_delete` at n≤200 is sub-millisecond and this
runs on the `/ws-ticket` HTTP path — once per connection **setup**, never per audio
frame. Not a latency risk for the voice path. One real edge case: the table is
`:public, :set` without `write_concurrency: true` (`tickets.ex:117`), so many
simultaneous `/ws-ticket` POSTs (e.g., a reconnect storm after a network blip) serialize
on ETS's table-wide write lock across `select_delete` + `insert`. At n≤200 this is
still fast, but `write_concurrency: true` is a one-line defensive change if reconnect
storms become a realistic scenario.

### 4. `router.origin_allowed?/1` calling `LiveCeci.config()` — confirmed off the hot path, and mostly skipped
`router.ex:60-68`: `LiveCeci.config()` is only reached via the right-hand side of
`host in @loopback_hosts or origin in LiveCeci.config().allowed_origins` — Elixir's
`or` short-circuits, so on a loopback-bound deployment (the documented default) the
`Application.get_env` calls never run at all. Even when they do run, it's once per
`/ws` upgrade or `/ws-ticket` POST — connection setup, not per frame. No issue.

### 5. `pcm-processor.js` end-of-speech detection — cheap additions, no new allocations
`pcm-processor.js:75-91`: the added manual-turn-detection logic (rising/falling edge
tracking, `_below`/`_openFor` counters, two threshold comparisons) reuses the RMS
already computed for barge-in in the existing one-pass loop (`:66-72`). Every added
operation per render quantum (~375/sec) is O(1) integer/float arithmetic — no new
array or object allocation on the audio thread. `_endTurn`/`_flush`
(`:93-107`) only allocate (`frame.slice`, `postMessage` payload objects) on
utterance boundaries (~10/sec or less), not per quantum. No issue.

### 6. Default 5 s `GenServer.call` timeouts on `Sessions`/`Tickets` — inconsistent with the rest of the codebase's discipline, low severity
Every call on the audio hot path in this codebase is explicitly timeout-guarded
(`live_session.ex:36`, `grok.ex:338`, `gemini.ex:99`) specifically because a default
5 s `GenServer.call` timeout raises an exit in the caller. `Sessions.join/1`
(`sessions.ex:48`) and `Tickets.issue/consume` (ETS-based, not a call, so N/A) don't
carry that guard — but `join/1` is off the per-frame path (see #2), so the blast
radius if it ever fires is a slow connection *attempt*, not a stalled audio stream.
Noted for consistency, not urgent.
