# live-dj-ex — performance audit (real-time audio streaming)

Scope: BEAM process mailboxes, binary handling, WebSocket frame throughput, per-connection
memory. Findings only.

Verified call chain for one mic chunk:

```
Bandit conn process (= LiveDJ.Socket)  handle_in/2                       socket.ex:91
  -> GenServer.call(session, {:send_realtime_input, ...})   [5_000 ms]   deps/gemini_ex/.../session.ex:239
     -> Base.encode64 + Jason.encode!                                    session.ex:449, websocket.ex:268
     -> :gen.call(websockex_pid, :"$websockex_send", ...)   [5_000 ms]   deps/websockex/lib/websockex.ex:471
        -> TLS write to Gemini
```

Three synchronous process hops, two 5-second timeouts, one JSON encode and one base64 encode,
**per chunk**.

---

## H1 — Mic chunks are emitted once per 128-sample render quantum: ~375 WebSocket frames/sec of ~85 bytes each

**Severity: HIGH** (this is the multiplier on every other cost in the system)

`priv/frontend/pcm-processor.js:9-33` — `process()` is invoked once per AudioWorklet render
quantum (128 frames). `priv/frontend/pcm-processor.js:31` posts a message on *every* invocation
with no accumulation, and `priv/frontend/main.js:98-101` forwards each one straight to
`ws.send()`.

Quantified, at a 48 kHz context (`ratio = 3`):

| | value |
|---|---|
| render quanta/sec | 48000 / 128 = **375** |
| samples per message | 128 / 3 ≈ 42.7 |
| **payload per WS frame** | **~85 bytes** |
| **frames/sec/listener** | **375** |

Downstream amplification per listener:

- Browser -> server: 85 B payload + 6 B masked WS header + ~29 B TLS record + 40 B TCP/IP
  ≈ **160 B on the wire for 85 B of audio (1.9x)**, at 375 packets/sec.
- Server -> Gemini (`session.ex:449` -> `websocket.ex:268`): `Base.encode64(85)` = 116 chars,
  wrapped in `{"realtimeInput":{"audio":{"data":"…","mimeType":"audio/pcm;rate=16000"}}}`
  (74 fixed chars) ≈ 190 B JSON, ≈ 260 B with TLS/TCP.
  **~97 KB/s of egress for 32 KB/s of audio (3.0x)**, at 375 TLS records/sec.
- 375 `GenServer.call`/sec, 375 `Jason.encode!`/sec, 375 `Base.encode64`/sec,
  750 `Telemetry.execute`/sec, ~1,125 inter-process message hops/sec — **per listener**.

**At 10x concurrent listeners:** 3,750 `handle_in/2`/sec, 3,750 JSON encodes, 3,750 base64
encodes, 7,500 telemetry executes, **~11,250 process context switches/sec**, 3,750 TLS writes/sec,
and ~970 KB/s egress for 320 KB/s of actual audio. The scheduler work is dominated by
per-message overhead, not by the audio itself.

**Fix** — buffer in the worklet to ~100 ms (1600 samples @ 16 kHz = 3200 bytes) before posting.
In `pcm-processor.js`, accumulate decimated samples into a class-level array and only
`postMessage` when `>= 1600` samples are ready (keep emitting `rms` per quantum if barge-in
responsiveness matters — or compute a running RMS and send it with the flushed chunk):

```js
constructor() { super(); this.ratio = sampleRate / 16000; this._frac = 0; this._buf = []; }
// ... in process(), push decimated samples into this._buf, then:
while (this._buf.length >= 1600) {
  const slice = this._buf.splice(0, 1600);
  const int16 = new Int16Array(1600);
  for (let i = 0; i < 1600; i++) { const s = Math.max(-1, Math.min(1, slice[i])); int16[i] = s < 0 ? s * 0x8000 : s * 0x7fff; }
  this.port.postMessage({ pcm: int16.buffer, rms }, [int16.buffer]);
}
```

Result: **375 -> 10 messages/sec (37.5x reduction)** in frames, GenServer calls, JSON encodes,
telemetry calls and TLS records; Gemini egress amplification drops from 3.0x to **1.34x**
(4.3 KB per chunk at 10/sec = 43 KB/s). 100 ms is well inside the Live API's expected chunking
and adds ~50 ms of average input latency — negligible against network + model latency.

---

## H2 — `send_realtime_input` is a blocking `GenServer.call` on the socket process with the default 5 s timeout, and a timeout kills the connection

**Severity: HIGH**

`lib/live_dj/socket.ex:91` (and identically `lib/live_dj/minimal.ex:46`).

`Session.send_realtime_input/2` is `GenServer.call(session, {:send_realtime_input, opts})`
(`deps/gemini_ex/lib/gemini/live/session.ex:239`) — **no timeout argument is exposed**, so it is
the 5,000 ms default. Inside, it calls `WebSockex.send_frame/2`, itself a `:gen.call` with its
own 5,000 ms timeout (`deps/websockex/lib/websockex.ex:463,471`), which blocks until the TLS
write completes.

Three consequences:

1. **A `GenServer.call` timeout is an `exit` raised in the *caller*, and `Process.flag(:trap_exit, true)`
   at `socket.ex:44` does not catch it.** `trap_exit` only converts exit *signals* from linked
   processes into messages; it does nothing for an exit raised inside the calling process. So a
   Gemini socket that stalls for 5 s **crashes the browser connection**, and `handle_in/2`'s
   `{:error, reason}` clause at `socket.ex:95-97` is dead code for the timeout case — it only
   ever fires for `{:not_ready, status}` (`session.ex:461`). Failure mode at 10x listeners: a
   Gemini-side stall or TLS backpressure event drops **every** connection simultaneously, and
   nothing reconnects (see M3).
2. **Head-of-line blocking between directions.** `handle_in` and `handle_info` are the same
   process. While blocked upstream, no `{:push, ...}` of Gemini voice can happen, so downstream
   playback stalls for exactly as long as the upstream call blocks — adding jitter directly to
   `nextStart` scheduling on the client (see M4).
3. Backpressure *does* exist toward the browser (ThousandIsland uses `active: :once`,
   `deps/thousand_island/lib/thousand_island/handler.ex:583-599`, so at most one extra TCP
   message sits in the mailbox), but it manifests as TCP window fill -> unbounded
   `ws.bufferedAmount` growth in the browser, which `main.js:99` never checks.

**Fix** — wrap the library call in a project-owned module and (a) pass an explicit timeout,
(b) survive the exit rather than dying:

```elixir
defmodule LiveDJ.LiveSession do
  @send_timeout 15_000
  def send_audio(session, pcm) do
    blob = Gemini.Live.Audio.create_input_blob(pcm)
    GenServer.call(session, {:send_realtime_input, [audio: blob]}, @send_timeout)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
```

and call `LiveDJ.LiveSession.send_audio(session, pcm)` at `socket.ex:91`. Dropping a chunk is
strictly better than dropping the call. (This also satisfies the "wrap third-party APIs behind
project-owned modules" rule, which `socket.ex` currently violates by calling
`Gemini.Live.Session` directly.) Combined with H1 the blocking cost drops 37.5x as well.

---

## M1 — Unbounded socket mailbox on the downstream side; ~13 KB retained per queued message

**Severity: MEDIUM**

`lib/live_dj/socket.ex:59-62` — `on_message`, `on_transcription`, `on_error` and `on_close` are
all bare `send/2` into the socket process. There is **no flow control in that direction at all**:
the session process pushes as fast as Gemini delivers, and nothing bounds the queue.

There is no selective receive anywhere and no unmatched-message accumulation — `handle_info/2`'s
catch-all at `socket.ex:144-147` consumes everything, and Bandit forwards all mailbox messages to
`WebSock.handle_info/2` — so the mailbox drains whenever the process is running. The risk is
purely "while the process is blocked", which H2 makes a routine event.

Memory per queued message is larger than it looks. `Jason.decode` produces the base64 audio
string as a **sub-binary of the whole decoded JSON payload**
(`deps/gemini_ex/lib/gemini/live/session.ex:523`). Sub-binaries are passed by reference across
`send/2` (no data copy — good) but they **retain the entire parent binary**. For a typical
~4.8 KB PCM output chunk that is ~6.4 KB of base64 inside a ~13 KB JSON payload, all of which
stays alive as long as the message sits in the mailbox.

Quantified: a 5 s upstream stall (i.e. exactly the H2 window) queues ~5 s x 48 KB/s of 24 kHz
audio ≈ **240 KB of PCM held as ~650 KB of retained JSON payloads**, plus one `ServerMessage`
struct per chunk, plus a second `{:transcription, ...}` message per `serverContent`
(`session.ex:757-763` invokes `on_message` *and* `handle_transcription`).

**Fix** — bound it explicitly. Either set `max_heap_size` on the upgrade so a runaway connection
is killed rather than taking the node down, or drop stale voice under pressure:

```elixir
# in handle_info, before pushing:
{:message_queue_len, len} = Process.info(self(), :message_queue_len)
if len > 200, do: {:ok, state}, else: {:push, frames, state}
```

Fixing H2 (so the process is never blocked for seconds) removes the practical trigger; the bound
is defence in depth.

---

## M2 — Unbounded transcript DOM growth: one `<div>` per streamed transcription fragment, with a forced reflow each time

**Severity: MEDIUM** — this is the frontend's real long-session leak, not `activeSources`.

`priv/frontend/main.js:21-26`. `addLine` appends a new element to `#transcript` on **every**
`{"type":"transcript"}` message, and `socket.ex:117-120` pushes one for every transcription
callback. Both `input_audio_transcription` and `output_audio_transcription` are enabled
(`socket.ex:57-58`) and the Live API streams these as **incremental fragments**, not
one-per-utterance — several per second while either party is speaking.

Over a 30-minute session that is thousands of never-removed DOM nodes. Worse, line 25 writes
`txEl.scrollTop = txEl.scrollHeight` immediately after `appendChild`, forcing a **synchronous
layout on every fragment** against a monotonically growing subtree — cost grows with session
length.

**Fix** — cap the buffer and coalesce consecutive fragments from the same role into the last
line instead of creating a node per fragment:

```js
let lastLine = null, lastRole = null;
function addLine(role, text) {
  if (role === lastRole && lastLine) { lastLine.textContent += text; }
  else {
    const p = document.createElement("div");
    p.className = "line " + role;
    p.textContent = (role === "mira" ? "mira  " : "you  ") + text;
    txEl.appendChild(p); lastLine = p; lastRole = role;
    while (txEl.childElementCount > 200) txEl.removeChild(txEl.firstChild);
  }
  requestAnimationFrame(() => { txEl.scrollTop = txEl.scrollHeight; });
}
```

---

## M3 — A dropped connection is unrecoverable, and the mic is never released

**Severity: MEDIUM** (turns any of H2/L1 into a dead session rather than a hiccup)

`priv/frontend/main.js:79` sets the status to "the line dropped — tap to reconnect", but
`main.js:107` disabled `#talk` at the start of `go()` and **nothing ever re-enables it**, and
`go()` is not idempotent anyway (it would create a second `AudioContext` and a second
`getUserMedia` stream). `onclose` also never calls `micStream.getTracks().forEach(t => t.stop())`
or `audioCtx.close()`, so the mic indicator stays on and the AudioWorklet keeps running and
keeps `postMessage`-ing at 375 Hz into a closed socket for the life of the page.

**Fix** — in `ws.onclose`, stop the worklet/mic, re-enable `#talk`, and make `go()` reconnect the
socket only (guard `startMic()` behind `if (!audioCtx)`).

---

## M4 — `nextStart` has no drift ceiling and barge-in does not discard in-flight audio

**Severity: MEDIUM**

`priv/frontend/main.js:62-63`. `nextStart += ab.duration` with a floor at `currentTime` is the
right *shape*, but there is no upper clamp. Gemini bursts a turn's audio faster than real time,
so `nextStart` legitimately runs ahead — and any server-side stall (H2) that then releases a
backlog (M1) schedules all of it contiguously, so playback latency is `nextStart - currentTime`
and only ever recovers at a silence boundary.

Compounding it, `stopVoice()` (`main.js:68-71`) resets local state on barge-in, but the server
keeps delivering the remainder of the interrupted turn's frames — Gemini's `interrupted` flag
arrives *before* the in-flight audio drains. Each late frame re-enters `playVoice`, sets
`speaking = true` and starts playing the audio the user just interrupted.

`activeSources` itself does **not** leak: `src.onended` (`main.js:65`) removes each source, and
the `filter` rebuild is O(n) per ended source (O(n²) per turn) but n is ~50-150 chunks — a few
thousand operations, immaterial. The leak claim in the brief does not hold; these two are the
real playback problems.

**Fix** — (a) clamp drift: if `nextStart - now > 1.0`, drop the chunk or reset to
`now + 0.05`; (b) add a barge-in generation counter, incremented in `stopVoice()`, and ignore
`playVoice` calls whose generation is stale for ~250 ms after a barge-in.

---

## L1 — `timeout: 60_000` is an *idle read* timeout with no server-side keepalive

**Severity: LOW** (real but narrow)

`lib/live_dj/router.ex:27`. `websock_adapter` maps `:timeout` to Bandit's `idle_timeout`
(`deps/websock_adapter/lib/websock_adapter.ex:84`), which ThousandIsland implements as a read
timer that is **reset on every continuation** — including `handle_info` returns
(`deps/thousand_island/lib/thousand_island/handler.ex:589-597`). So while the mic streams at
375 Hz, or while Gemini pushes voice, it never fires.

It *does* fire when the client stops producing: a backgrounded tab whose `AudioContext` gets
suspended, or a paused/muted mic during a quiet stretch with no model output. There is no
server-side ping (`socket.ex` never sends `{:ping, ...}`), so the connection is closed at 60 s
and M3 makes that terminal.

**Fix** — either send a periodic `{:ping, ""}` from a `Process.send_after/3` heartbeat in
`socket.ex`, or raise `timeout:` to `120_000` and rely on the client sending a keepalive. Note
that H1's batching moves the client from 375 msg/s to 10 msg/s — still far inside 60 s, so H1
does not create a timeout risk.

---

## L2 — `max_frame_size: 1_000_000` is ~12,000x the actual frame size

**Severity: LOW**

`lib/live_dj/router.ex:27`. Actual client frames are ~85 bytes today (H1) and would be ~3,200
bytes after the fix. A 1 MB ceiling lets any client force a 1 MB per-connection buffer
allocation, which at 10x+ concurrency is free memory amplification with no legitimate use.

**Fix** — `max_frame_size: 65_536`. That is 20x headroom over a 100 ms batched chunk and still
rejects abuse early.

---

## L3 — Two `Telemetry.execute` calls per audio chunk, each doing an `Application.get_env` plus a recursive `redact/2` map walk

**Severity: LOW**

`deps/gemini_ex/lib/gemini/live/session.ex:1123-1129` (`emit_telemetry_message_sent`) and
`deps/gemini_ex/lib/gemini/client/websocket.ex:771-781` (`emit_send`) both fire on every
`send_realtime_input`. Each goes through `Gemini.Telemetry.execute/3`
(`deps/gemini_ex/lib/gemini/telemetry.ex:68-74`), which does an `Application.get_env(:gemini_ex,
:telemetry_enabled)` and then recursively `redact/2`s both the measurements and metadata maps.
`emit_send` additionally runs `detect_message_type/1` — an `Enum.find_value` with two `Map.has_key?`
probes per candidate (`websocket.ex:837-843`).

At 375 chunks/sec that is **750 telemetry executes/sec/listener, 7,500/sec at 10x**, with no
handlers attached anywhere in this project (no `:telemetry.attach` in `lib/`). Individually cheap;
collectively pure waste.

**Fix** — `config :gemini_ex, telemetry_enabled: false` in `config/prod.exs`. H1 independently
cuts this 37.5x.

---

## L4 — `Session.connect/1` blocks `init/1` for up to 30 s, then a stale audio backlog is flushed

**Severity: LOW**

`lib/live_dj/socket.ex:73-74`. `Session.connect/1` is `GenServer.call(session, :connect, 30_000)`
(`session.ex:156`) covering a TLS handshake plus `wait_for_setup_complete` with its own 30 s
receive (`session.ex:684-688`). The WebSock `init/1` runs in the Bandit connection process, so
the browser's socket is already accepted and the client (`main.js:98-101`) starts sending as soon
as `readyState === OPEN`.

`active: :once` means only one packet is buffered in the mailbox, but the rest sit in the OS
receive buffer / TCP window. When `init/1` returns, `handle_in/2` drains a backlog of audio that
is by then 0.5-2 s old and forwards it to Gemini as if it were live, which the model's VAD sees
as a burst of past speech. Also, the ThousandIsland read timer is not armed until the
continuation returns, so a slow connect is invisible to the idle timeout.

**Fix** — connect asynchronously: return `{:ok, %{session: session, ready: false}}` from `init/1`,
kick `Session.connect/1` off in a `Task`, drop binary frames while `ready: false`, and flip the
flag on `setup_complete`. Discards ~1 s of pre-roll audio instead of replaying it stale.

---

## Clean areas (one line each)

- **`voice_frames/1` + `++`** (`socket.ex:111,181-188`): non-issue. `parts` is almost always a
  single element and `interrupted_frame/1` returns `[]`, so the `++` copies a 1-cons list at
  ~10-20 messages/sec. Immeasurable. (Unrelated robustness note, since it is on the hot path:
  the pattern `%{inline_data: %{"data" => b64}}` mixes an atom key with a string key — a part
  arriving with `%{inline_data: %{data: ...}}` would be silently dropped as audio loss, not an
  error.)
- **Base64 decode cost** (`socket.ex:182` -> `Audio.decode_output/1`): non-issue. 24 kHz mono s16
  is 48 KB/s of PCM per session = 64 KB/s of base64; `Base.decode64!` runs at hundreds of MB/s.
  Decoding happens in the socket process, which is the correct side. Large binaries cross the
  session -> socket boundary **by reference** (refc/sub-binary), not copied. The only memory
  concern is the retained parent payload, covered in M1.
- **Selective receive / unmatched message accumulation**: none. `socket.ex:144-147` consumes
  everything; `Logger.debug` there is **not** a hot-path cost — the Logger macro evaluates its
  argument lazily behind a level check, the configured level is `:info` in dev and prod
  (`config/dev.exs:2`, `config/prod.exs:2`), and no audio message reaches that clause anyway
  (they match at `socket.ex:110` / `socket.ex:115`). Worth knowing: raising the level to `:debug`
  for troubleshooting would `inspect/1` `ServerMessage` structs containing full base64 audio, both
  here and at `deps/gemini_ex/lib/gemini/live/session.ex:517`.
- **Per-frame config lookups**: none. `LiveDJ.config/0` is called once in `init/1`
  (`socket.ex:47`); `router.ex:24`'s `Application.get_env` is once per HTTP upgrade, not per
  frame. (`minimal.ex:29,33` calls `LiveDJ.config()` twice in `init/1` — cosmetic, once per
  connection.)
- **Per-connection process model**: correct. One socket process, one linked session process, no
  shared bottleneck between listeners, no global registry or singleton in the audio path.

## Not set, worth setting

`websock_adapter` accepts `:fullsweep_after` and `:max_heap_size` on
`WebSockAdapter.upgrade/4` (`deps/websock_adapter/lib/websock_adapter.ex:96`) and neither is
configured at `router.ex:27`. These are long-lived processes churning refcounted binaries at
tens of KB/sec in both directions — the textbook case for
`fullsweep_after: 20, max_heap_size: 50_000` on the upgrade options, which forces the connection
process to reclaim binary references promptly and caps a runaway mailbox (M1) at the process
rather than the node.
