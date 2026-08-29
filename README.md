# live-ceci-ex — a voice agent you can interrupt, in Elixir

Talk to **Ceci**, a late-night radio DJ. Ask her to play something. Talk over her mid-sentence and she stops, listens, and picks the thread back up.

An Elixir port of [`live-dj`](../live-dj) — the demo from **EP1 of the Multimodal Agents Cookbook**. **No Phoenix and no agent framework**, so the whole primitive stays visible.

Two backends sit behind the same bridge: the **Gemini Live API** via [`gemini_ex`](https://hex.pm/packages/gemini_ex), and **xAI's Voice Agent**. `MODEL` in `.env` picks one. The browser cannot tell the difference — both negotiate the 16 kHz up / 24 kHz down PCM the client already speaks, so nothing in `priv/frontend` changes either way.

## Run it

Requires Elixir `~> 1.17` (developed on 1.20 / OTP 29).

```bash
cp .env.example .env          # paste GROK_API_KEY, or GOOGLE_API_KEY with MODEL=GOOGLE
mix deps.get

mix run --no-halt
```

Open <http://localhost:8000>, **put headphones on** (otherwise she hears her own radio), tap 🎙 and talk.

Try: *"hey Ceci"* · *"can you play something dream pop"* · *"skip this"* — then **talk over her** while she's speaking.

### Configuration

`config/runtime.exs` ships a ten-line dotenv reader, so the Python repo's `.env` works unchanged and we skip a dependency. It only fills in variables that aren't already set — real deployments just set the environment.

| Variable | Default | What it does |
|---|---|---|
| `MODEL` | `GROK` | `GROK` or `GOOGLE` — which backend answers |
| `LANGUAGE` | — | locale for the voice, POSIX or BCP-47 spelling (`pt_BR` and `pt-BR` both work). Omitted entirely when unset; both APIs reject a null here. |
| `GOOGLE_API_KEY` / `GEMINI_API_KEY` | — | either name works; `gemini_ex` wants the second, the Python repo's `.env` has the first. Missing it warns at boot (except in `:test`). |
| `GOOGLE_LIVE_MODEL` | `gemini-3.1-flash-live-preview` | the Gemini Live model |
| `GOOGLE_LIVE_VOICE` | `Aoede` | Ceci's **native Live** voice |
| `GROK_API_KEY` | — | required when `MODEL=GROK` |
| `GROK_LIVE_MODEL` | `grok-voice-latest` | the xAI voice model |
| `GROK_LIVE_VOICE` | `eve` | Ceci's xAI voice |
| `PORT` | `8000` | the HTTP port |
| `SILENCE_DURATION_MS` | `400` | how long a provider's VAD waits in silence before deciding your turn is over. A hard floor under every answer — nothing comes back until it elapses. `0..10000` |
| `FRAME_SAMPLES` | `1600` | mic batch size in 16 kHz samples; `1600` = 100 ms. Reaches the browser's AudioWorklet through `GET /config.json`. `160..16000` |

The last two are latency knobs, and `priv/spike/latency_bench.exs` measures what moving them buys. Both fall back **loudly**: `SILENCE_DURATION_MS=30O` (letter O) warns at boot rather than silently reverting to the default and invalidating the next benchmark run.

`LiveCeci.config/0` reads the resolved values back out, at call time — so what `runtime.exs` writes at boot is what the session opens with.

## How it works

The browser owns the audio (mic worklet down to 16 kHz, 24 kHz playback, barge-in). The server owns the socket. The model owns the turn.

```
Browser ──ws──> Bandit ──> LiveCeci.Socket          (one process per browser)
                              │  send_realtime_input/2
                              ▼
                           Gemini.Live.Session    (linked GenServer)
                              │  callbacks -> send(owner, msg)
                              ▼
                           handle_info/2 ──> binary voice + JSON to the browser
```

Where the Python version runs **two asyncio tasks** (mic up, audio down), the BEAM needs neither: the socket process *is* both directions. `handle_in/2` is upstream, `handle_info/2` is downstream, and the Live session is a linked GenServer pushing into our mailbox.

`LiveCeci.Application` starts exactly one child — `{Bandit, plug: LiveCeci.Router, port: port}`. Bandit supervises the per-connection processes, so there is no hand-rolled supervision tree to get wrong.

## The module that matters, and the seam under it

[`LiveCeci.Socket`](lib/live_ceci/socket.ex) is the whole app: one browser socket in, one model session out, and everything that makes Ceci *Ceci* layered on top of that single bridge.

The primitive underneath is four steps — open a session, send the mic up, receive voice back, push it to the browser. `Socket` adds the persona, the tools, transcription, and `Process.flag(:trap_exit, true)`, so a session crash becomes an `{:EXIT, …}` message it can report instead of a silent death.

What it does *not* do any more is know which API answered. [`LiveCeci.Provider`](lib/live_ceci/provider.ex) is a behaviour over six neutral events:

```
{:voice, pcm}   :interrupted   {:transcript, :user | :ceci, text}
{:play, cmd}    {:error, _}    {:closed, _}
```

The two wire formats disagree about nearly everything — Gemini pushes typed structs through callbacks and takes audio by reference; xAI speaks a JSON event protocol and takes raw binary frames — so neither vocabulary makes a good lingua franca. Providers translate into the set above, and decoding is theirs: by the time a frame reaches the socket it is PCM, not base64 and not a struct.

The behaviour has no `send_tool_result/3`, and that omission is load-bearing. `gemini_ex` wants a tool result as the callback's **return value**, synchronously, while the model's voice is paused; xAI wants two separate messages. No single signature fits both without being dead weight in one, so each provider dispatches through `LiveCeci.Tools` itself. The decision stays shared; only the handshake differs.

## The gotcha — and the one that vanished

The Python original exists to teach a bug: `session.receive()` is a **per-turn** async generator, so a naive `async for` makes the agent answer one sentence and go silent forever. It needs an outer `while True`.

**That bug cannot be written in Elixir.** `Gemini.Live.Session` is a GenServer that *pushes* every server message through callbacks — there is no generator to exhaust and no loop to forget to restart. The actor model deletes the entire class of bug, which is good engineering and a worse demo.

Its sibling **does** survive, in [`LiveCeci.Socket`](lib/live_ceci/socket.ex): mic audio goes to `send_realtime_input`, **not** `send_client_content`. `send_client_content` is for seeding history before the conversation; point the mic at it and the live turn never fires, so you get dead air.

And the rule that governs [`LiveCeci.Tools`](lib/live_ceci/tools.ex): live function calls are **synchronous**, so the model's voice is paused until your tool returns. `dispatch/2` is therefore a plain function over plain data — no GenServer call, no HTTP, no `Task.await`. It decides a command, hands it to the socket process, and returns `%{result: "ok"}` in the same breath. `test/live_ceci/tools_test.exs` fails if one starts doing real work.

## Why no Phoenix

The wire contract here is **raw binary PCM frames**. Phoenix Channels would only wrap them in a JSON envelope, and LiveView can't own the audio path anyway — mic worklet and PCM playback are necessarily JS. So: `Bandit` + `Plug` + `WebSockAdapter.upgrade/4`, which is smaller and a closer match to what the app does.

Phoenix earns its place at the *next* step — multi-user, auth, Presence, deploy, a server-rendered UI. Then mount this same `WebSock` handler in a Phoenix router and let LiveView drive only the chrome.

## What's inside

| | |
|---|---|
| `lib/live_ceci.ex` | `config/0` — the resolved model, voice, and port |
| `lib/live_ceci/application.ex` | starts Bandit on `PORT`, and nothing else |
| `lib/live_ceci/socket.ex` | the bridge — provider-agnostic, six events wide |
| `lib/live_ceci/provider.ex` | the behaviour, and why it has no `send_tool_result/3` |
| `lib/live_ceci/provider/gemini.ex` | Gemini Live, through `gemini_ex` |
| `lib/live_ceci/provider/grok.ex` | xAI's Voice Agent, hand-rolled on `websockex` — no Elixir package speaks the OpenAI Realtime protocol |
| `lib/live_ceci/live_session.ex` | the one upstream Gemini call, with its own timeout and `catch :exit` — a stalled session must not take the listener down |
| `priv/spike/grok_voice_spike.exs` | the throwaway script that verified the xAI protocol against the live API before any of it was written — including whether manual turn detection beats server VAD |
| `priv/spike/latency_bench.exs` | TTFA, both backends, interleaved — see [Measuring latency](#measuring-latency) |
| `lib/live_ceci/tools.ex` | `play_playlist` / `play_track` / `skip` / `pause` — they return **instantly**, so the voice never stalls |
| `lib/live_ceci/persona.ex` · `priv/assets/ceci_persona.txt` | who Ceci is — read at **compile time**, with `@external_resource` so editing the text triggers a recompile |
| `lib/live_ceci/router.ex` | the WebSocket upgrade + static files + `/healthz` |
| `config/runtime.exs` | the `.env` reader and the API-key aliasing |
| `priv/frontend/` | the browser client, **copied unchanged** from the Python repo |
| `priv/assets/tracks/` · `priv/assets/tracks.json` | four dream-pop tracks and the catalogue the browser fetches |

The frontend is byte-identical to the Python original: the WebSocket contract did not change, so nothing needed porting.

Dependencies, in full: `bandit`, `plug`, `websock_adapter`, `websockex`, `gemini_ex`, `jason`, plus `mix_audit` in dev/test. That's the list.

`gemini_ex` is pinned to the minor (`~> 0.17.0`, not `~> 0.17`). It is a 0.x library that has already moved the Live WebSocket transport once in a minor release, `LiveCeci.Provider.Gemini` pattern-matches its structs in function heads, and `LiveCeci.LiveSession` calls one of its internal messages directly — so drift surfaces as a runtime error, not a compile one.

## The HTTP surface

| Route | |
|---|---|
| `GET /` · `GET /main.js` · `GET /pcm-processor.js` | the client, served from `priv/frontend` |
| `GET /assets/*` | `tracks.json` and the four mp3s, from `priv/assets` |
| `GET /healthz` | `200 ok` |
| `GET /config.json` | `{"frameSamples":N}` — the only channel between `FRAME_SAMPLES` in `.env` and the AudioWorklet that applies it |
| `GET /ws` | the WebSocket upgrade — 60 s timeout, 1 MB max frame |

## Measuring latency

```bash
set -a && . ./.env && set +a && mix run --no-start priv/spike/latency_bench.exs
```

It starts its own listener on a free port, so it can flip the backend between
connections and **interleave** GROK and GOOGLE trials — running eight of one and then
eight of the other would make any drift in the route indistinguishable from a
difference between the models. `BENCH_TRIALS` sets the count (default 8 each);
`BENCH_WAV` points at your own 16 kHz mono s16le recording instead of the one `say`
generates.

It reports exactly one number, **TTFA**: from the last byte of your utterance to the
first byte of voice back. That is the only measurement the two APIs make comparable.
Transcript timings are deliberately *not* raced — Gemini streams the assistant
transcript in fragments while she is still speaking, xAI sends it only once the whole
text exists, so timing "first transcript" would measure protocol granularity and hand
Google a few hundred milliseconds it did not earn.

Read the result as a comparison, not an absolute. `SILENCE_DURATION_MS` is added to
every number and is identical on both sides, so it compresses the relative difference.

### What it measured — 2026-08-29

20 trials per backend, interleaved, no failures. `SILENCE_DURATION_MS=300`,
`FRAME_SAMPLES=1500`, `LANGUAGE=pt-BR`, one 4.27 s pt-BR utterance, from Brazil.
`gemini-3.1-flash-live-preview` / `Aoede` against `grok-voice-latest` / `luna`.

| backend | n | p50 | p95 | min | max | sd |
|---|---|---|---|---|---|---|
| **Gemini Live** | 20 | **1220 ms** | 1569 ms | 1022 ms | 1728 ms | 170 |
| **xAI Voice Agent** | 20 | **1806 ms** | 2027 ms | 1684 ms | 2210 ms | 120 |

586 ms apart at the median, and the distributions barely touch: exactly **1 of 20**
Gemini trials landed above xAI's *minimum*. With the trials interleaved, that is not
route drift. Note the direction of the spread, though — xAI is the slower one but the
steadier one (sd 120 vs 170).

**Where the difference is not.** The bench also records when the user's transcript
comes back, purely as a did-the-audio-land check. It turns out to be the interesting
number:

| | user transcript (p50) | TTFA (p50) | the remainder |
|---|---|---|---|
| Gemini Live | 793 ms | 1220 ms | **427 ms** |
| xAI Voice Agent | 790 ms | 1806 ms | **1016 ms** |

Closing the turn and transcribing the speech costs **the same 790 ms on both — a 3 ms
difference**. The entire 586 ms gap appears downstream of that, in generation and the
first TTS chunk, where xAI takes 2.4× as long.

That settles the question the two providers invite you to ask, and in the opposite
direction to the intuition. xAI carries audio as raw binary frames; Gemini base64s it
inside JSON, paying 33% on the wire and an encode per mic frame. But transport only
touches the upstream leg — which is precisely the half where the two are identical —
and the backend that *has* binary transport is the slower one overall. At 100 ms per
frame the base64 tax is ~1068 bytes, under a millisecond of serialisation on any real
link. It is not where the latency lives.

So the budget, with the settings above:

```
 300 ms   VAD silence            configured — yours to move
~490 ms   ASR + network          identical on both
 427 ms   Gemini: generation + first TTS chunk
1016 ms   xAI:    generation + first TTS chunk
```

**Caveats.** One utterance, one language, one ~10-minute window, one network path. The
`heard at` figures also disagree in spread even where they agree in median — xAI's ASR
threw outliers at 1130, 1216 and 1740 ms (sd 236) where Gemini stayed between 772 and
978 (sd 63).

**Two levers still unpulled on the xAI side**, both found while verifying the above:

- `session.reasoning.effort` accepts `"high"` or `"none"` and this app never sets it,
  so Grok runs on whatever the default is. If that default is `high`, it is the obvious
  suspect for 1016 ms of generation — and it is one field.
- Manual turn detection works. `turn_detection.type` takes `null`, and probe 9 of the
  spike measured **1186 ms manual against 3353 ms with server VAD** on the same audio.
  That is n=1 and on a different clip than the table above, so treat the direction as
  real and the magnitude as unmeasured. It trades the VAD wait for whatever the
  browser's own gate decides, and with it the risk of turns that fire early.

## The WebSocket contract

`WS /ws` — unchanged from the Python server.

- **Browser → server:** binary frames, 16 kHz mono PCM s16le. Text frames are accepted and ignored; the contract reserves them for `{"type":"start"|"stop"}`, which the client doesn't send today.
- **Server → browser:** binary frames of 24 kHz PCM (voice), plus JSON text frames:
  `{"type":"transcript","role":"user"|"ceci","text":…}` ·
  `{"type":"play","action":"playlist"|"track"|"skip"|"pause","value":…}` ·
  `{"type":"interrupted"}` · `{"type":"error","message":…}`

Empty transcripts are dropped rather than drawn as blank lines, and a text-only model part pushes nothing — this agent speaks, it does not type.

## Tests

```bash
mix test
mix format --check-formatted
mix deps.audit          # advisory database; mix hex.audit only reads retirement flags
```

**123 tests, no network:**

| | |
|---|---|
| `provider/grok_test.exs` (33) | xAI events in, neutral events out — binary voice and the base64 fallback, barge-in, transcripts, tool dispatch, the session shape including the configurable silence budget, and that the tool reply goes out by `cast`, because `WebSockex.send_frame/3` **raises** when the caller is the socket process |
| `provider/gemini_test.exs` (25) | real `gemini_ex` structs in, neutral events out — the assertions that lived in `socket_test.exs` before the seam existed, plus the session options the API actually reads |
| `socket_test.exs` (14) | the bridge at the message-translation level, mentioning neither vendor: neutral events in, real WebSocket frames out, plus a stub provider proving the upstream call goes through whichever one is configured |
| `tools_test.exs` (12) | dispatch, the four declarations, atom- and string-keyed args, the JSON round-trip, and the instant-return guardrail — measured twice, because wall clock catches blocking and reductions catch work, and neither catches both |
| `live_ceci_test.exs` (12) | `config/0` reads at call time so a boot-time override wins, the test VM asks the OS for a port, `pt_BR` normalises to `pt-BR`, and `env_int/3` falls back **loudly** on every plausible `.env` typo |
| `router_test.exs` (9) | `/healthz`, `/config.json`, the 404 catch-all, the static client, the track catalogue and audio files — and that `priv/assets/ceci_persona.txt` is **not** reachable over HTTP |
| `socket_lifecycle_test.exs` (6) | the socket opened and closed for real over TCP, so `terminate/2` actually runs — the path that leaked billed provider sessions when it did not |
| `agent_name_test.exs` (5) | the agent is Ceci, in the instruction, in the `:ceci` atom, in the `"ceci"` role on the wire, and nowhere in `lib/` or `priv/frontend` under the old name |
| `persona_test.exs` (4) | the instruction loads, carries both halves, names every callable tool, and is shaped as the `Content` the setup message expects |
| `live_session_test.exs` (3) | a stalled or dead session comes back as `{:error, {:exit, _}}` and the caller stays alive — the guardrail on the one call that sits in the audio path |

Real `gemini_ex` structs in, real WebSocket frames out. `config/test.exs` sets a dummy API key so config validation passes without one.

## Notes

- **Voice** is a Gemini Live *native* voice (`LIVE_VOICE`, default `Aoede`) — the Live API has its own voice set, so it can't reproduce a TTS voice you used elsewhere. The persona carries the character, not the timbre.
- **Barge-in** is client-side: the browser cuts playback the instant the mic hears you (RMS gate at `0.02` in `priv/frontend/main.js`). The server forwards `interrupted` too.
- **Mic framing.** The worklet batches PCM into ~100 ms frames rather than emitting one per 128-sample render quantum — at 48 kHz that was 375 WebSocket frames/sec of ~85 bytes, where framing overhead dwarfed the audio. Barge-in can't wait for the batch, so a quantum that crosses the gate posts an RMS-only message immediately and the cut stays instant.
- **Ducking** is client-side as well: the music drops to 12 % while Ceci talks and comes back 450 ms after she stops.
- **Concurrency** is where the port pays off. The Python design doc lists *"what breaks at 10× concurrent: one process holding N sessions saturates."* Here each listener is an isolated, supervised process; one dropped call never touches another.
