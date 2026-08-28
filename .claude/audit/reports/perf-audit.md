# live-dj — performance audit (latency & throughput)

Scope: `socket.ex`, `live_session.ex`, `tools.ex`, `main.js`, `pcm-processor.js`, `persona.ex`.
Every cost below is traced to a line I read, including the `gemini_ex`, `bandit`, `thousand_island`
and `websockex` code the hot path actually reaches.

## Reference numbers used throughout

| Quantity | Value | Source |
|---|---|---|
| Mic frame | 1600 samples / 3200 bytes / 100 ms | `pcm-processor.js:10` |
| Mic frame rate | 10 /s | ditto |
| Worklet `process()` rate @48 kHz ctx | 375 /s (128-sample quantum) | `pcm-processor.js:22` |
| Downstream voice | 24 kHz s16le = 48 000 B/s PCM = 64 000 B/s as base64 | `Audio.decode_output`, `socket.ex:188` |
| Upstream per frame on the wire | 3200 B PCM → 4272 B base64 → ~4.3 KB JSON | `session.ex:969`, `websocket.ex:267` |

---

## P1 — Unbounded downstream mailbox: a wedged browser buffers ~1.9 MB of voice per connection before anything notices

**`lib/live_dj/socket.ex:116-133`, `lib/live_dj/application.ex:12`**

The downstream path has no flow control anywhere along its length:

1. `gemini_ex` invokes `on_message` / `on_transcription` with a bare `send/2`
   (`deps/gemini_ex/lib/gemini/live/session.ex:759` and `:866,:870` → `invoke_callback`), wired to
   `&send(owner, {:gemini, &1})` at `socket.ex:60-61`. `send/2` never blocks and never signals fullness.
2. `handle_info/2` converts each to `{:push, frames, state}`.
3. Bandit turns each frame in that list into exactly one `:gen_tcp.send`
   (`deps/bandit/lib/bandit/websocket/connection.ex:300-320` → `ThousandIsland.Socket.send/2` at
   `deps/thousand_island/lib/thousand_island/socket.ex:102-113`).

`:gen_tcp.send` is the *only* backpressure in the system, and it is applied to the wrong thing: it
blocks **the socket process**, which is also the only consumer of the mailbox that is filling up.

**How long it blocks:** ThousandIsland defaults to `send_timeout: 30_000, send_timeout_close: true`
(`deps/thousand_island/lib/thousand_island/transports/tcp.ex:24-25`). `application.ex:12` starts
Bandit with only `plug:` and `port:`, so that default stands. One browser whose receive window
closes — a throttled background tab, a phone on a bad link — parks the socket process inside
`:gen_tcp.send` for **up to 30 seconds**.

**Measurable impact, per stalled connection:**

- Mailbox: Gemini keeps producing at ≥64 000 B/s of base64 (it generates a turn's audio faster than
  real time). 30 s × 64 KB/s ≈ **1.9 MB of queued binaries plus `ServerMessage`/`ServerContent`
  structs**, with no cap and no log line.
- GC amplification: the queued *terms* live on the process heap. The default `fullsweep_after` is
  65535, and `bandit/websocket/handler.ex:14-16` only applies `:fullsweep_after`/`:max_heap_size` if
  they were passed in `connection_opts` — `router.ex:26` passes neither. So the socket process grows
  a large heap and repeatedly copies the backlog during minor GCs.
- Upstream damage: `handle_in/2` is called by Bandit **in this same process**, so it is not running
  either. The kernel receive buffer fills, then the browser's send buffer. When the send finally
  unblocks, the socket drains up to 300 queued mic frames back-to-back — 300 `GenServer.call`s
  shipping ~1.3 MB of base64 of *stale* audio into Gemini, which the model will answer.
- The router's `timeout: 60_000` (`router.ex:26`) does not help: it is a read-idle timeout, not a
  write timeout.

**Fix (three parts, all small):**

```elixir
# application.ex — a 2 s write deadline instead of 30 s; ThousandIsland closes the socket after it
{Bandit,
 plug: LiveDJ.Router,
 port: port,
 thousand_island_options: [transport_options: [send_timeout: 2_000]]}
```

```elixir
# socket.ex init/1, next to the trap_exit flag at :45
Process.flag(:trap_exit, true)
Process.flag(:message_queue_data, :off_heap)  # backlog stops being GC'd with the heap
Process.flag(:fullsweep_after, 10)            # release refc binaries promptly
```

```elixir
# socket.ex — shed voice when we are already behind. Late real-time audio is worthless.
@max_queue 40  # ~1-2 s of Gemini chunks

def handle_info({:gemini, %ServerMessage{server_content: %ServerContent{} = sc}}, state) do
  {:message_queue_len, qlen} = Process.info(self(), :message_queue_len)

  cond do
    qlen > @max_queue and not interrupted?(sc) ->
      # drop voice only; control frames below still get through
      {:ok, state}

    true ->
      frames = interrupted_frame(sc) ++ voice_frames(sc)
      if frames == [], do: {:ok, state}, else: {:push, frames, state}
  end
end
```

`Process.info(self(), :message_queue_len)` on the *local* process is an O(1) word read — it is safe
to call per message. Note the reordering: the `interrupted` control frame should precede any trailing
audio in the same message, so the browser flushes before it plays.

---

## P1 — Head-of-line blocking: a wedged Live session blocks the socket 100 % of the time, and shrinking the timeout does not fix it

**`lib/live_dj/socket.ex:97`, `lib/live_dj/live_session.ex:24,33-37`**

The upstream chain per mic frame is **two synchronous process hops**, not one:

```
socket proc --GenServer.call(1 s)--> Session GenServer --:gen.call(5 s)--> WebSockex proc --> TLS
             live_session.ex:33      session.ex:449-451   websockex.ex:471
```

`WebSockex.send_frame/2` is itself a `:gen.call` with a 5 s default
(`deps/websockex/lib/websockex.ex:463,471`), and `session.ex:451` calls it inside `handle_call`
with no catch. So a stalled TLS write wedges the Session GenServer for the full 5 s.

**What the socket process loses while one call is in flight.** The `GenServer.call` selective
receive is *not* the problem — the ref is created immediately before the receive, so the BEAM's
receive-mark optimisation prevents any re-scan of the mailbox. The problem is that nothing else in
the process runs:

- Downstream `{:gemini, …}` messages queue and are not pushed. A 1 s stall = a **1 s hole in Mira's
  voice**, caused entirely by an upstream problem.
- `handle_in/2` is not re-entered (Bandit drives it from this same process), so mic frames back up
  in the TCP receive buffer and arrive as a burst afterwards.

**Is 1 s the right order of magnitude?** No — but the interesting part is that lowering it alone
buys nothing. A healthy `send_audio` is sub-millisecond (two process hops plus a base64 + JSON
encode of 3.2 KB). A *stalled* one is stalled because the Session is wedged in its own 5 s
`send_frame`. `handle_in/2` at `socket.ex:97` retries unconditionally on the very next frame, so:

| `@send_timeout` | Calls during a 5 s Session wedge | Socket blocked |
|---|---|---|
| 1000 ms (today) | 5 | **5000 ms — 100 %** |
| 250 ms | 20 | **5000 ms — still 100 %** |

The socket is dead for the whole wedge either way, because it re-enters the call the instant the
previous one gives up.

**Fix — shorten the timeout *and* add a hold-off so the retries stop:**

```elixir
# live_session.ex — 2.5 frame periods absorbs jitter; 10 frame periods does not help anyone
@send_timeout 250
```

```elixir
# socket.ex — state gains :upstream_blocked_until (init to 0)
def handle_in({pcm, [opcode: :binary]}, %{session: session} = state) when session != nil do
  now = System.monotonic_time(:millisecond)

  if now < state.upstream_blocked_until do
    {:ok, state}                                   # drop, do not even call
  else
    case LiveDJ.LiveSession.send_audio(session, pcm) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        Logger.warning("send_realtime_input failed: #{inspect(reason)}")
        {:ok, %{state | upstream_blocked_until: now + 1_000}}
    end
  end
end
```

With `250 ms` timeout + `1000 ms` hold-off, the same 5 s wedge blocks the socket for 250 ms out of
every 1250 ms — **20 % instead of 100 %** — so downstream voice keeps flowing through the outage
instead of going silent with it.

**Do not "fix" this with a `Task`.** Moving the call off-process would remove the blocking but also
remove frame ordering, and PCM delivered out of order is worse than PCM delivered late.

**Related, unfixable from this repo but worth knowing:** the Session GenServer is a *bidirectional*
serialisation point. It handles upstream `{:send_realtime_input, …}` (`session.ex:448`) and
downstream `{:gemini_websocket, …, {:text, data}}` (`session.ex:494` → `Jason.decode!` + struct
build + callbacks) in the same mailbox. Per-frame upstream work of `Base.encode64(3200)` +
`Jason.encode!(~4.3 KB)` + telemetry (`session.ex:969`, `websocket.ex:267`, `:771`) therefore delays
downstream parsing. At 10 frames/s that is ~1-2 ms/s — negligible normally, total during a stall.
The actionable consequence: never add work to that process. The `on_tool_call` discipline in
`socket.ex:64-67` is exactly right and must stay.

---

## P2 — Barge-in gate posts up to 375 messages/sec, undoing the 100 ms batching it sits next to

**`priv/frontend/pcm-processor.js:50`**

```js
if (rms >= this._bargeRms) this.port.postMessage({ rms });   // barge-in fast path
```

The comment on lines 8-9 says "a quantum whose level **crosses** the gate posts an RMS-only message".
The code is level-triggered, not edge-triggered: it posts on *every* quantum that is above the gate.

`process()` runs 375 times/sec at a 48 kHz context. `BARGE_RMS` is 0.02
(`pcm-processor.js:20`, `main.js:9`), and `getUserMedia` is opened with `autoGainControl: true`
(`main.js:100`), which pushes ordinary speech RMS to 0.05-0.3. So for the entire duration of any
utterance the worklet emits **375 objects/sec across the MessagePort**, each structured-cloned and
each waking the main thread — against the 10 pcm messages/sec the batching in lines 3-6 was written
to achieve. That is **~37× the cross-thread traffic the file's own header claims to have eliminated**,
landing on the main thread that is simultaneously running `playVoice` (`main.js:59`), `JSON.parse`,
and DOM work.

`main.js:109` makes the flood mostly idempotent (`&& speaking` short-circuits after the first one),
but the port dispatch and task scheduling happen regardless.

**Fix — edge-trigger, and let the main thread tell the worklet when it even matters:**

```js
// constructor
this._above = false;
this._speaking = false;
this.port.onmessage = (e) => { this._speaking = !!e.data.speaking; };

// end of process()
const above = rms >= this._bargeRms;
if (above && !this._above && this._speaking) this.port.postMessage({ rms });
this._above = above;
```

```js
// main.js — mirror playback state into the worklet
function setSpeaking(v) {
  speaking = v;
  workletNode && workletNode.port.postMessage({ speaking: v });
}
```

This turns 375 msg/sec into **at most one message per barge-in event**, with identical barge-in latency.

---

## P2 — Per-quantum heap allocation on the audio render thread

**`priv/frontend/pcm-processor.js:28-33`**

```js
const out = [];
...
out.push(ch[Math.floor(idx)]);
```

A fresh JS `Array` is allocated on **every** `process()` call — 375/sec — and grown by `push` from
capacity 0 to ~43 elements, which costs several internal reallocations each time. This runs on the
audio render thread, which must complete a quantum in under 2.67 ms; the standard AudioWorklet rule
is that `process()` allocates nothing, because a GC pause on that thread is an audible dropout, not a
slow frame. This is the one place in the whole pipeline where an allocation is directly audible.

There is also a redundant second pass: lines 37-41 iterate `out` to clamp and accumulate RMS, then
lines 45-48 iterate it again to convert to int16.

**Fix — one preallocated scratch buffer, one fused loop, zero allocation:**

```js
// constructor
this._scratch = new Float32Array(256);   // ample for a 128-sample quantum at any ratio

// process()
const out = this._scratch;
let n = 0, idx = this._frac, sum = 0;
while (idx < ch.length) {
  let s = ch[idx | 0];
  s = s < -1 ? -1 : s > 1 ? 1 : s;
  out[n++] = s;
  sum += s * s;
  idx += this.ratio;
}
this._frac = idx - ch.length;
const rms = n ? Math.sqrt(sum / n) : 0;
if (rms > this._peak) this._peak = rms;
for (let i = 0; i < n; i++) {
  this._buf[this._len++] = out[i] < 0 ? out[i] * 0x8000 : out[i] * 0x7fff;
  if (this._len === FRAME_SAMPLES) this._flush();
}
```

`idx | 0` also replaces 43 `Math.floor` calls per quantum (~16 000/sec).

---

## P2 — One DOM node and one forced reflow per Gemini server message, not per turn

**`priv/frontend/main.js:25-32` (server side: `lib/live_dj/socket.ex:123-126`)**

`gemini_ex` fires `on_transcription` once per `serverContent` message
(`deps/gemini_ex/lib/gemini/live/session.ex:756-763` → `handle_transcription` at `:861-871`), i.e.
at the audio-chunk rate, not the turn rate. `socket.ex:123-126` pushes one `Jason.encode!` + one WS
text frame + one `:gen_tcp.send` for each. The browser then, per fragment:

- `JSON.parse` (`main.js:88`)
- `createElement` + `appendChild` — a brand-new `<div>` per fragment, so one spoken sentence becomes
  many divs rather than one growing line (`main.js:26-29`)
- `txEl.childElementCount` read + possible `removeChild` (`main.js:30`)
- **`txEl.scrollTop = txEl.scrollHeight`** (`main.js:31`) — reading `scrollHeight` right after a DOM
  mutation forces a **synchronous layout**, on the same main thread that is decoding and scheduling
  24 kHz voice buffers.

The `MAX_LINES = 60` cap (added by the comment at lines 21-23 to bound "thousands of turns") is
reached in a handful of seconds at this rate, so `removeChild` then runs on essentially every
message too.

**Fix — coalesce fragments into the current line instead of creating a new one, and stop forcing
layout on every one:**

```js
let lastRole = null, lastEl = null;
function addLine(role, text) {
  if (role === lastRole && lastEl) {
    lastEl.textContent += text;                 // same speaker still talking → extend the line
  } else {
    lastEl = document.createElement("div");
    lastEl.className = "line " + role;
    lastEl.textContent = (role === "mira" ? "mira  " : "you  ") + text;
    txEl.appendChild(lastEl);
    lastRole = role;
    while (txEl.childElementCount > MAX_LINES) txEl.removeChild(txEl.firstElementChild);
  }
  if (!scrollQueued) {                          // one forced layout per frame, not per fragment
    scrollQueued = true;
    requestAnimationFrame(() => { txEl.scrollTop = txEl.scrollHeight; scrollQueued = false; });
  }
}
```

The server side can stay as-is once the client coalesces; if you want the wire traffic down too,
buffer transcription text in socket state and flush on role change.

---

## P2 — Nothing is released when the socket closes: the mic, the AudioContext and the worklet run forever

**`priv/frontend/main.js:85`, `:96-113`, `:115-123`**

```js
ws.onclose = () => { setStatus("the line dropped — tap to reconnect"); setOrb("idle"); };
```

`onclose` releases nothing and reconnects nothing. Concretely, after any disconnect:

- `micStream` (`main.js:99`) is never `getTracks().forEach(t => t.stop())`-ed → the browser's
  recording indicator stays on for the life of the page.
- `audioCtx` (`main.js:97`) is never `close()`-d and `workletNode` is never `disconnect()`-ed, so the
  render thread keeps running `process()` **375 times/sec forever**, still allocating (P2 above),
  still posting PCM batches. `main.js:108` checks `ws.readyState` so nothing is transmitted — the CPU
  is burned for output that is discarded.
- The status text promises "tap to reconnect", but the only click handler is on `$("talk")`
  (`main.js:123`), which `go()` sets to `disabled = true` at `main.js:116` and never re-enables. There
  is no reconnect path at all.

**Fix:**

```js
function teardown() {
  if (workletNode) { workletNode.port.onmessage = null; workletNode.disconnect(); workletNode = null; }
  if (micStream) { micStream.getTracks().forEach((t) => t.stop()); micStream = null; }
  if (audioCtx) { audioCtx.close().catch(() => {}); audioCtx = null; }
  stopVoice();
}

ws.onclose = () => {
  teardown();
  setStatus("the line dropped — tap to reconnect");
  setOrb("idle");
  $("talk").disabled = false;
  $("talk").textContent = "talk to mira";
};
```

---

## P3 — `playVoice` copies every voice chunk twice

**`priv/frontend/main.js:60-64`**

```js
const f32 = new Float32Array(int16.length);          // alloc #1
for (...) f32[i] = int16[i] / 0x8000;                // fill
const ab = audioCtx.createBuffer(1, f32.length, 24000);
ab.getChannelData(0).set(f32);                        // alloc #2 + full memcpy
```

Two full-size Float32 buffers per chunk where one suffices — at 48 000 B/s of PCM that is ~96 KB/s of
avoidable Float32 allocation plus the memcpy, on the main thread, at the chunk rate.

**Fix:**

```js
const int16 = new Int16Array(buf);
const ab = audioCtx.createBuffer(1, int16.length, 24000);
const ch = ab.getChannelData(0);
for (let i = 0; i < int16.length; i++) ch[i] = int16[i] / 0x8000;
```

Also worth adding `src.disconnect()` inside the `onended` handler at `main.js:71`, so the graph node
is released rather than waiting on GC. The `activeSources.filter` there allocates a new array per
ended source, which is O(N²) over a turn; with N in the tens it is not worth restructuring, but the
`disconnect()` is free.

---

## P3 — `_flush()` copies 3.2 KB per frame that it then transfers away

**`priv/frontend/pcm-processor.js:53-57`**

```js
const frame = this._buf.slice(0, this._len);   // 3200-byte copy
this.port.postMessage({ pcm: frame.buffer, rms: this._peak }, [frame.buffer]);
```

Since the buffer is transferred (detached) anyway, the copy is unnecessary — transfer `_buf` itself
and allocate the replacement. Same allocation count, one fewer 3.2 KB memcpy, 10×/sec:

```js
const buf = this._buf.buffer;
this.port.postMessage({ pcm: buf, rms: this._peak }, [buf]);
this._buf = new Int16Array(FRAME_SAMPLES);
this._len = 0;
this._peak = 0;
```

Note this only holds while `_flush` is called exactly at `_len === FRAME_SAMPLES` (`:47`), which it is.

---

## P3 — `max_frame_size: 1_000_000` for a client that only ever sends 3200 bytes

**`lib/live_dj/router.ex:26`**

The browser sends fixed 3200-byte binary frames (`pcm-processor.js:10`) and no text frames
(`socket.ex:107-109`). A 1 MB ceiling lets any client make Bandit's extractor buffer 1 MB per frame
per connection before rejecting it. `16_384` covers the real protocol with 5× headroom.

Same line: pass `fullsweep_after: 10` here if you would rather configure it at the upgrade than in
`init/1` — `deps/bandit/lib/bandit/websocket/handler.ex:14-16` applies `:fullsweep_after` and
`:max_heap_size` from `connection_opts` as process flags, and `max_heap_size` would additionally give
the P1 mailbox growth a hard ceiling instead of an OOM.

---

## P3 — `String.to_atom/1` on a derived key in `dispatch`'s helper

**`lib/live_dj/tools.ex:77`**

```elixir
defp arg(args, key) when is_map(args), do: args[key] || args[String.to_atom(key)] || ""
```

Today `key` is always the literal `"mood"` or `"title"` from lines 68 and 71, so no unbounded atom
creation occurs and the runtime cost is one atom-table lookup on a path that fires only on a tool
call (rare). It is flagged only because it is a `String.to_atom` on a *parameter*: the moment a
future caller passes anything model- or user-derived it becomes the atom-exhaustion bug. Pass the
atom directly and delete the conversion:

```elixir
def dispatch("play_playlist", args), do: {%{action: "playlist", value: arg(args, "mood", :mood)}, %{result: "ok"}}
defp arg(args, str, atom) when is_map(args), do: args[str] || args[atom] || ""
defp arg(_args, _str, _atom), do: ""
```

---

## Clean areas (one line each, as requested)

- **`lib/live_dj/persona.ex`** — confirmed correct. `@external_resource` at `:11` plus
  `@persona @persona_path |> File.read!() |> String.trim()` at `:13` and the interpolated
  `@instruction` at `:15-23` mean the file is read by the *compiler*; `system_instruction/0` at `:35`
  returns a literal map from the module's constant pool. Zero disk I/O and zero string work per
  connection. Nothing to change.
- **`lib/live_dj/tools.ex` `dispatch/2` (`:67-75`)** — verified: pure head-pattern-match dispatch over
  literal maps, no I/O, no process interaction, no iteration, O(1) and allocation-bounded. The
  synchronous-voice-stall constraint documented at `:5-10` is genuinely honoured.
- **`lib/live_dj/socket.ex` `handle_in/2` own work** — the socket process's per-frame cost is a 2-key
  map, a 2-cons keyword list and a tuple (`live_session.ex:33-37`); `Audio.create_input_blob/2`
  defaults to `encode: false` (`deps/gemini_ex/lib/gemini/live/audio.ex:115-127`), so the 3200-byte
  binary is passed by reference and the base64 happens in the Session process. Nothing to hoist here —
  the issues are the blocking (P1) and the mailbox (P1), not the arithmetic.
- **`lib/live_dj/socket.ex` downstream frame building (`:117,:187-194,:208`)** — the `++` is against a
  one- or zero-element list and the `Base.decode64!` is unavoidable (the browser needs raw PCM).
- **per-message-deflate** — correctly *not* negotiated: `router.ex:26` omits `compress: true`, which
  `deps/bandit/lib/bandit.ex:201-203` requires per-upgrade. Incompressible 24 kHz PCM is therefore not
  being pointlessly zlib'd in both directions.

## Suggested order

1. P1 mailbox shedding + `send_timeout: 2_000` + the two process flags (`socket.ex`, `application.ex`) — this is the one that turns a bad network into a bounded failure rather than ~2 MB and a 30 s freeze.
2. P1 hold-off + `@send_timeout 250` (`socket.ex`, `live_session.ex`) — keeps voice flowing through an upstream stall.
3. P2 worklet edge-trigger + zero-alloc `process()` (`pcm-processor.js`) — both are contained rewrites of one function.
4. P2 transcript coalescing and P2 teardown (`main.js`).
5. The P3s as cleanup.
