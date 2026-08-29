# Performance Audit — live-ceci (latency & backpressure on the voice hot path)

Scope: `lib/`, `priv/frontend/`, `config/runtime.exs`. Plain OTP app, no Ecto/DB —
those checks don't apply and aren't repeated below. `LiveCeci.Tools.dispatch/2`
(`lib/live_ceci/tools.ex:114-166`) was verified: pure pattern-matching over maps and
strings, no GenServer call, no I/O, no loop over external work — it returns in
microseconds as required. No further N+1/dispatch findings there.

Baseline for context: 1220 ms p50 (Gemini) / 1806 ms p50 (xAI) utterance-end to
first-voice-byte, ~790 ms of which is identical VAD+ASR on both. Findings below are
ranked by how much avoidable latency/growth they can add on top of that budget.

---

## P1

### 1. One process serializes upstream send *and* downstream push — a slow provider ACK stalls voice in both directions at once
`lib/live_ceci/socket.ex:76-89` (`handle_in`) calls `provider.send_audio/2`
synchronously, in the same WebSock connection process that also owns
`handle_info`/`{:push, ...}` (`socket.ex:99-122`). For Gemini this resolves to
`lib/live_ceci/live_session.ex:33`, `GenServer.call(session, {:send_realtime_input,
...}, 1_000)`; for Grok to `lib/live_ceci/provider/grok.ex:68`,
`WebSockex.send_frame(ws, {:binary, pcm}, 1_000)`. Both are blocking calls, both
bounded at 1 s, both invoked **once per ~100 ms mic frame**.

Consequence: while that call is in flight, the socket process cannot execute
`handle_info` — so any voice/transcript/action frame already sitting in its mailbox,
ready to push to the browser, waits behind it. A single slow upstream ACK therefore
adds up to 1 s of jitter to *outgoing* voice, not just to the mic frame that triggered
it — on every ~100 ms frame, i.e. up to 10 times/sec of exposure. 1 s is comparable to
the entire measured p50 latency budget (1220/1806 ms), so if upstream ever degrades
(rather than fails outright, which is already handled by the `{:error, _}` clause at
`socket.ex:85-87`), the user-visible effect is stutter on Ceci's voice, not just a
delayed mic frame.

This isn't a bug in isolation — the 1 s bound and drop-and-continue behavior
(`live_session.ex:24-40`, `grok.ex:65-71`) are deliberate and documented, and are
better than the alternative (5 s default `GenServer.call` timeout exiting the
caller). The finding is that the mitigation caps the *damage per stall* but not the
*frequency* — every frame pays the same synchronous, same-process cost, so the
worst case is not rare. The same shape recurs one layer up and outside this repo's
control: `gemini_ex`'s `Gemini.Live.Session` (`0.17.0`,
`lib/gemini/live/session.ex:448-458`) does `state.websocket_module.send(...)`
synchronously inside `handle_call`, in the *same* GenServer process that also
receives and relays every downstream `{:gemini_websocket, ...}` message
(`session.ex:493-509`) — so a slow write to Google inside that call blocks Gemini's
relay to us too, compounding the stall before our 1 s guard even gets a chance to
fire.

### 2. Bandit/ThousandIsland `send_timeout` is not overridden — a stalled browser can hold the socket process (and its mailbox) for 30 s
`lib/live_ceci/application.ex:12` starts Bandit with only `plug:` and `port:`; the
WebSocket upgrade in `lib/live_ceci/router.ex:26` sets `timeout: 60_000` (the
*inactivity/read* timeout only). Neither sets `thousand_island_options:
[transport_options: [send_timeout: ...]]`. Verified against the installed dep
(`thousand_island-1.5.0`, `lib/thousand_island/transports/tcp.ex:24-25` and
`:53-54`): the transport default is `send_timeout: 30_000, send_timeout_close:
true`.

Consequence: if the browser stops reading (backgrounded/throttled tab, phone
screen-locked, flaky wifi) — a very ordinary occurrence for a persistent
long-lived WebSocket — the next `{:push, [{:binary, pcm}], state}` write
(`socket.ex:99`, and the other pushes at `:102`, `:106`, `:111`, `:116`) can block
the connection process for **up to 30 seconds** (25x the measured p50 latency)
before ThousandIsland gives up and force-closes. For that entire window:

- The provider session keeps streaming — `send(owner, {:provider, ...})` calls in
  `provider/grok.ex:104,130,141,152,158,176,181` and `provider/gemini.ex:107,110,120`
  are plain `send/2`, which **never blocks the sender**. Every voice/transcript/action
  event the provider produces during the stall queues in this one process's mailbox
  with no cap and no drop policy — this is the unbounded growth the audit asked to
  find.
- The same process also can't service `handle_in`, so mic frames back up at the TCP
  layer instead (self-limiting via the OS receive window — comparatively benign next
  to the mailbox growth above).

Fix: set an explicit, short `send_timeout` (2-5 s is plenty for a same-region
listener) via `{Bandit, plug: LiveCeci.Router, port: port, thousand_island_options:
[transport_options: [send_timeout: 3_000, send_timeout_close: true]]}` so a dead
listener is dropped in a few seconds instead of 30, bounding the mailbox exposure
to roughly one order of magnitude less time.

---

## P2

### 3. Per-render-quantum array allocation on the audio thread
`priv/frontend/pcm-processor.js:34-72` (`process()`) runs once per 128-sample
render quantum — ~375 times/sec at 48 kHz. Lines 40-46 allocate a fresh plain JS
`Array` (`const out = []`) and grow it via `.push()`, then iterate it twice more
(clip+RMS at `:49-53`, copy-into-`Int16Array` at `:56-59`) — three passes and one
heap allocation per quantum, on the one thread where a GC pause reads as an audible
glitch. Not evidenced as currently causing dropouts, but it's the one per-quantum
allocation site the audit asked to look for, and it's avoidable: a fixed-size scratch
`Float32Array` sized to the worst-case decimation output (`ceil(128 / ratio) + 1`),
written by index instead of `push`, removes both the allocation and one of the three
passes.

### 4. No backpressure on the outbound (mic) WebSocket send from the browser
`priv/frontend/main.js:120` — `ws.send(e.data.pcm)` fires unconditionally whenever
`ws.readyState === WebSocket.OPEN`, with no check of `ws.bufferedAmount`. If the
network to the server degrades, the browser queues frames internally with no cap
and no drop policy on our side, while the worklet keeps producing a new frame every
~100 ms regardless (`pcm-processor.js:58,77`) — nothing tells it a send is falling
behind. This is the client-side mirror of finding 2's mailbox growth: unbounded
growth in the browser's own send buffer during a sustained stall. A guard on
`ws.bufferedAmount` (skip or coalesce frames past a small threshold, e.g. 2-3
frames' worth) would cap it.

---

## P3

### 5. `activeSources` has no bound and no eviction path if `onended` never fires
`priv/frontend/main.js:16,67-68` — entries are removed only via `src.onended`.
Unlike the transcript pane (`MAX_LINES`, `main.js:24,30`) and activity panel
(`MAX_ACTIONS`, `:44,51`), which both defensively prune, there's no analogous cap
here. If playback stalls without `stopVoice()` running (context suspended by
background-tab throttling, autoplay policy, etc.), sources accumulate for the rest
of the session. Low individual cost (~4.8 KB per stuck 100 ms/24 kHz buffer) and
low likelihood, but it's the one growable structure on the voice path without a
ceiling.

### 6. Unguarded, default-timeout `GenServer.call` in `terminate/2` — inconsistent with the rest of the codebase's call-guarding
`lib/live_ceci/socket.ex:135-138` calls `provider.close(session)` on every
connection teardown. For Grok this is a non-blocking `WebSockex.cast`
(`provider/grok.ex:79`, correctly fire-and-forget, as its own comment explains). For
Gemini, `provider/gemini.ex:75-78` calls `Session.close(session)`, which is
`GenServer.call(session, :close)` in `gemini_ex` (`lib/gemini/live/session.ex:279`)
with the **default 5 s timeout and no catch** — the exact hazard that
`live_session.ex`'s whole module doc and `grok.ex:261-265`'s `send_json/2` were
written to guard against elsewhere in this codebase. If the Gemini session is wedged
at shutdown time, this can add up to 5 s to closing that one connection, and an
unguarded exit here happens inside `terminate/2`. Blast radius is a single
connection (each socket is its own process), so this is low severity, but it's the
one call-site on the close path that doesn't follow the pattern the rest of the
code is careful about.
