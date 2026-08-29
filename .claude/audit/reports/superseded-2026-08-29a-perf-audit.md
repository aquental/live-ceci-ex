# Performance Audit — live-ceci (memory, backpressure, unbounded growth)

Scope: `lib/live_ceci/socket.ex`, `lib/live_ceci/live_session.ex`,
`lib/live_ceci/provider/{gemini,grok}.ex`, `lib/live_ceci/sessions.ex`,
`lib/live_ceci/tickets.ex`, `lib/live_ceci/application.ex`, `lib/live_ceci/router.ex`,
`priv/frontend/{main,pcm-processor}.js`. Plain OTP app, no Ecto/DB/Phoenix — not
applicable, not repeated below.

Not re-derived (given, trusted as measured): per-100ms-frame reduction/latency costs
through `Socket`, `LiveSession`, `Grok.send_audio`, `Base.encode64` (Gemini-only, inside
gemini_ex, not `create_input_blob`), `Tools.dispatch` flatness, `Tickets.issue` ~17µs,
`Sessions.join` p95 1µs/max 6µs, and the ~985ms/1220ms provider-dominated end-to-end
latency. This report supersedes the prior `perf-audit.md`, whose headline P1 (Gemini's
mic path blocking the socket process) is now fixed: `lib/live_ceci/live_session.ex`
did not exist at that audit and now carries the blocking Gemini call off the socket
process entirely — confirmed fixed, not re-reported.

---

## P1

### 1. `activeSources`'s overflow guard is dead code — the browser tab's real memory bound on a long call does not exist
`priv/frontend/main.js:80-87`:
```js
if (activeSources.length > MAX_SOURCES) {
  activeSources = activeSources.filter((s) => s.__done !== true);
}
src.onended = () => {
  src.__done = true;
  activeSources = activeSources.filter((s) => s !== src);
  ...
};
```
`__done` is only ever set to `true` *inside* `onended`, and the same synchronous
callback that sets it also removes that element from `activeSources` in the same
tick (`s !== src`). There is no code path that leaves an element in the array with
`__done === true`. So the filter at line 81 — the comment above it calls it a "sweep"
against exactly the case where `onended` doesn't fire — can never remove anything: any
element still in the array by definition has `__done !== true` already. `MAX_SOURCES`
(300, `main.js:14`) is checked but never enforced.

Consequence: the moduledoc-adjacent comment (`main.js:76-79`) names the real failure
modes itself — "a suspended context, a tab in the background, or a source stopped in
a way the browser does not report" — and in every one of them, `activeSources` grows
by one `AudioBufferSourceNode` + one already-decoded `AudioBuffer` (24 kHz Float32,
~9.6 KB per 100 ms chunk at typical provider chunking) per voice frame, for the rest
of the call, with nothing capping it. A backgrounded tab during an hour-long call —
not a corner case for a voice assistant meant to run in a browser tab — accumulates
roughly 36,000 sources/buffers at 10 frames/sec, ~345 MB of raw PCM float data alone
before per-object overhead, and the tab either OOMs or the audio graph degrades long
before the user notices anything else wrong.

Fix shape: either make the filter correct (track `Date.now()` per source and evict by
age past its expected `duration`, since `__done` genuinely cannot do this job), or move

> **RETRACTED by the orchestrator after verification.** The finding below claims
> `WebSockex.start_link` has no connect timeout and defaults to `:infinity`, citing
> `deps/websockex/lib/websockex/utils.ex:31`. That line is `do_spawn(:link, args)`
> calling `:proc_lib.start_link/3` — there is no `:infinity` there and no timeout at all.
>
> WebSockex does bound both halves of the handshake:
> `deps/websockex/lib/websockex/conn.ex:10-11` sets
> `@socket_connect_timeout_default 6000` and `@socket_recv_timeout_default 5000`, wired
> into the `%Conn{}` defaults at lines 21-22. Worst case a stalled connect to xAI holds a
> Sessions slot for about 11 seconds, not indefinitely, and the slot is released when the
> socket process dies either way.
>
> The finding is left in place rather than deleted so the reasoning that produced it can
> be checked, not repeated.


to `AudioBufferSourceNode.addEventListener` + an explicit epoch counter that doesn't
depend on `onended` firing at all.

### 2. `Grok.open/1`'s `WebSockex.start_link` has no connect timeout — a stalled upstream handshake hangs the WS upgrade forever, not just the reconnect
`lib/live_ceci/provider/grok.ex:56-58`:
```elixir
case WebSockex.start_link(url, __MODULE__, %{owner: owner},
       extra_headers: [{"Authorization", "Bearer " <> key}]
     ) do
```
No `:timeout` option. `WebSockex.start_link/4` → `Utils.spawn/5` →
`:proc_lib.start_link(WebSockex, :init, args)` (`deps/websockex/lib/websockex/utils.ex:31`)
with no timeout argument, which defaults to `:infinity` — the TCP+TLS connect to
`wss://api.x.ai/v1/realtime` can hang indefinitely on a black-holed SYN or a stalled
TLS handshake. This runs inside `LiveCeci.Socket.init/1` (`socket.ex:75-93`), which
runs *inside* Bandit's `handle_connection` (`deps/bandit/lib/bandit/websocket/handler.ex:28`)
— and confirmed by reading that file: the `timeout:` option passed to
`WebSockAdapter.upgrade/4` (`router.ex:143`, `60_000`) is only installed as a
`{:persistent, timeout}` idle timer **after** `Connection.init/4` (which runs our
`Socket.init/1`) returns (`handler.ex:28-33`). There is no framework-level bound on
`init/1` itself.

Consequence: `LiveCeci.Sessions.join/1` (`socket.ex:47`) already succeeded and holds a
slot before `open_session/0` calls `Grok.open/1` — so a hung connect attempt pins one
of the default 4 per-address slots (`max_sessions_per_address`, `sessions.ex:161`) for
however long the OS-level TCP connect takes to give up (often 60–130s on a black-holed
SYN on Linux, or truly forever if the remote accepts the TCP connection but never
completes TLS/HTTP). A user "hitting reconnect repeatedly" against a flaky network path
to xAI can pin all 4 per-address slots within a handful of attempts and lock themselves
out with 1013 refusals until the OS eventually gives up — self-inflicted denial of
service, and indistinguishable from the server actually being at capacity. Contrast
with `close/1` (`@close_timeout 1_000`, `grok.ex:33`) and `send_json/2`
(`@send_timeout 1_000`, `grok.ex:361`), which are both explicitly bounded — the connect
step is the one gap. `Gemini.open/1` does not have this gap: `Session.connect/1` is a
`GenServer.call(session, :connect, 30_000)` — bounded, if 30x looser than the other
budgets in this codebase.

Fix shape: pass `:timeout` in the `opts` given to `WebSockex.start_link/4` (a few
seconds, matching `@send_timeout`/`@close_timeout`'s existing 1_000 discipline), and
release the Sessions slot on that path exactly like the existing
`{:error, reason} -> close(ws); {:error, reason}` branch already does for a failed
`send_json`.

---

## P2

### 3. Per-session provider processes are held together by links alone, with no independent count
Confirmed process shape per session: `Grok` = Bandit connection process (the socket) +
one `WebSockex` process. `Gemini` = Bandit connection process + one
`Gemini.Live.Session` (gemini_ex) + one `LiveCeci.LiveSession` carrier. Confirmed
correct today: neither `WebSockex` (no `trap_exit` anywhere in
`deps/websockex/lib/websockex.ex`) nor `Gemini.Live.Session`
(no `trap_exit` in `deps/gemini_ex/lib/gemini/live/session.ex`) traps exits, and both
are `start_link`'d from inside the socket process, so a socket crash correctly cascades
to kill its provider process(es), and a provider crash correctly reaches the socket via
`Process.flag(:trap_exit, true)` (`socket.ex:64`) → the `{:EXIT, pid, reason}` clause
(`socket.ex:177-180`).

What's missing: none of these processes sit under a `Supervisor`, and
`LiveCeci.Sessions.total/0` (`sessions.ex:88-89`) only counts *socket* pids, never
provider/carrier pids. `application.ex:12-29` supervises only `Tickets`, `Sessions`,
and the `Bandit` listener. There is no independent accounting that would notice a
provider process outliving its socket. This is not hypothetical here: `Gemini.ex`'s
own moduledoc documents *two* historical instances of exactly this leak
(`provider/gemini.ex:38-44` — `open/1` dropping `session` on a failed `connect`, leaked
because the Sessions slot is keyed to the socket pid, not the upstream session;
`provider/gemini.ex:65-70` — `Session.close/1` stopping the websocket but leaving the
GenServer running) — both since patched, per the moduledoc's own account, by code
review rather than by any structural safety net. A third such bug, in either provider
module, would again leak invisibly: `Sessions.total/0` would still report the correct
socket count while a provider process sits there billed and un-tracked, and nothing in
this codebase would surface it besides log volume, if that.

### 4. `Sessions`/`Tickets` are not the bottleneck at 8 or 100 concurrent sessions — the real ceiling is external
Modeled explicitly, since the audit asked: `Sessions.join/1` is a `GenServer.call` at
connection-open only (once per socket lifetime, never per frame), already measured at
p95 1µs / max 6µs. `count_for/2` (`sessions.ex:153-155`) is `Enum.count/2` over the
holders map, `O(map_size(holders))` — at the default cap of 8 that's noise; at the
configurable ceiling of 100 (or the code's actual allowed range, 1..1000 per
`env_int` in `config/runtime.exs`) it is still a single-digit-microsecond linear scan.
`Tickets.issue/1`/`consume/2` run in the *caller's* process against a `:public,
read_concurrency: true` ETS table (`tickets.ex:181`) — genuinely concurrent, no
GenServer round trip at all for the hot path of minting/spending a ticket. Neither
module serializes anything that scales with session count in a way that matters at
either 8 or 100.

Two minor, real costs found while modeling it: `router.ex:132` (`Sessions.available?`)
and `socket.ex:47` (`Sessions.join`) are two sequential `GenServer.call`s to the same
singleton per successful connection, not one — ~2×(1–6µs), harmless in isolation but
doubling the serialized load on the one process gating every connection in the system,
worth remembering if `MAX_SESSIONS` and reconnect frequency both grow well past today's
defaults.

The actual first thing that breaks at 100 concurrent sessions is not in this codebase:
each session holds 2 open sockets (1 browser, 1 upstream) and 2–3 BEAM processes, so
100 sessions ≈ 200 sockets / ~250–300 processes — trivial for the VM, but worth
confirming against the deployment's `ulimit -n` before raising `MAX_SESSIONS` toward
1000. Far more likely to bind first: 100 simultaneous Live-API WebSocket sessions
against a single xAI or Gemini API key hitting that provider's own concurrent-session
or QPS ceiling — nothing in this codebase measures or tests that, so `provider.open/1`
would start returning `{:error, reason}` at whatever the provider's real limit is, with
no distinguishing signal to the operator beyond a generic connect failure log. Anyone
raising `MAX_SESSIONS` past single digits should verify the account tier first; this
code has nothing to say about it either way.

---

## P3

### 5. `MAX_SOURCES` is the only bound in this list that isn't just conservative — it doesn't bind anything
Reviewing every bound named: `@max_queued 20` (`live_session.ex:42`, `grok.ex:84`) ≈ 2s
of mic audio at 10 fps before dropping — reasoned, holds. `@max_queued 40`
(`socket.ex:140`) downstream, double the upstream bound to absorb bursts from
providers that don't pace audio in real time — reasoned, holds. `MAX_BUFFERED 32000`
(`main.js:12`) ≈ 1s of 16kHz s16 mono — matches its own comment, holds. `@max_outstanding
200` / `@max_per_address 20` (`tickets.ex:61,67`) are deliberately generous relative to
`max_sessions 8` because tickets are cheap and Sessions is the real gate — by design,
holds. `max_sessions 8` / `max_sessions_per_address 4` (`sessions.ex:157,161`) — sane
defaults for loopback. `MAX_SOURCES 300` (`main.js:14`) is the outlier: it is not too
tight or too loose, it simply never fires, per finding #1 — a bound that exists in the
source but not in the running program.

### 6. No growth found in gemini_ex's per-session state over a long call
Checked specifically because the audit asked about accumulation over an hour:
`Gemini.Live.Session`'s `usage_metadata` is *replaced*, not appended
(`deps/gemini_ex/lib/gemini/live/session.ex:766`: `usage || state.usage_metadata`), and
the rest of its state (`websocket`, `status`, `config`, `session_handle`) is fixed-size
and doesn't grow with conversation length. `LiveCeci.LiveSession`'s own state
(`%{session: session, dropped: count}`, `live_session.ex:65`) is a pid and a bare
integer counter — no per-frame accumulation. No transcript, history, or PCM buffer is
held server-side anywhere in this codebase; every frame is decoded, forwarded, and
dropped from the mailbox on delivery.

### 7. Startup/reconnect cost is bounded everywhere except the one gap in #2
End-to-end open cost, walked step by step: ticket mint (~17µs, ETS, given) → cap check
(`Sessions.available?` + `Sessions.join`, ~2×1–6µs, see #4) → provider open (network-
bound, provider-dominated) → `session.update`/setup (Gemini: `Session.connect`
bounded at 30_000ms; Grok: `send_json` bounded at `@send_timeout 1_000`). Every step
our code controls is either microsecond-scale or explicitly timeout-guarded, with the
sole exception of Grok's initial `WebSockex.start_link` (P1 #2). A user mashing
reconnect against a *healthy* upstream pays only real provider RTT each time (the
~985ms/1220ms budget already measured) — the reconnect-storm risk is specifically the
degraded-network case covered above, not the happy path.
