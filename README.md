# live-ceci-ex — a voice agent you can interrupt, in Elixir

Talk to **Ceci**, the operational assistant from [ceci.pro](https://ceci.pro): she takes the admin side of a therapy practice — scheduling, attendance, receipts, the accountant's monthly summary — and never touches the clinical side. Talk over her mid-sentence and she stops, listens, and picks the thread back up.

**No Phoenix and no agent framework**, so the whole primitive stays visible.

Two backends sit behind the same bridge: the **Gemini Live API** via [`gemini_ex`](https://hex.pm/packages/gemini_ex), and **xAI's Voice Agent**. `MODEL` in `.env` picks one. The browser cannot tell the difference — both negotiate the 16 kHz up / 24 kHz down PCM the client already speaks, so nothing in `priv/frontend` changes either way.

## Run it

Requires Elixir `~> 1.17` (developed on 1.20 / OTP 29).

```bash
cp .env.example .env          # paste GROK_API_KEY, or GOOGLE_API_KEY with MODEL=GOOGLE
mix deps.get

mix run --no-halt
```

Open <http://localhost:8000>, **put headphones on** (otherwise she hears her own voice), tap 🎙 and talk — in Portuguese; her instruction and her tools are pt-BR.

Try: *"oi Ceci"* · *"marca a M.S. terça às 14h"* · *"emite o recibo de 250"* · *"fecha o resumo de agosto"* — then **talk over her** while she's speaking. Ask her something clinical and she should decline and steer back.

### Configuration

`config/runtime.exs` ships a ten-line dotenv reader so a `.env` beside the project works without pulling a dependency for it. It only fills in variables that aren't already set — real deployments just set the environment.

| Variable | Default | What it does |
|---|---|---|
| `MODEL` | `GROK` | `GROK` or `GOOGLE` — which backend answers |
| `LANGUAGE` | — | locale for the voice, POSIX or BCP-47 spelling (`pt_BR` and `pt-BR` both work). Omitted entirely when unset; both APIs reject a null here. |
| `GOOGLE_API_KEY` / `GEMINI_API_KEY` | — | either name works; `gemini_ex` wants the second, AI Studio hands you the first. Missing it warns at boot (except in `:test`). |
| `GOOGLE_LIVE_MODEL` | `gemini-3.1-flash-live-preview` | the Gemini Live model |
| `GOOGLE_LIVE_VOICE` | `Aoede` | Ceci's **native Live** voice |
| `GROK_API_KEY` | — | required when `MODEL=GROK` |
| `GROK_LIVE_MODEL` | `grok-voice-latest` | the xAI voice model |
| `GROK_LIVE_VOICE` | `eve` | Ceci's xAI voice |
| `PORT` | `8000` | the HTTP port |
| `BIND_IP` | `127.0.0.1` | which address the listener binds. Bandit's own default is `0.0.0.0`, which puts an unauthenticated WebSocket in front of a metered API on the open LAN. Opening this is the deliberate opt-in |
| `SILENCE_DURATION_MS` | `400` | how long a provider's VAD waits in silence before deciding your turn is over. A hard floor under every answer — nothing comes back until it elapses. `0..10000` |
| `MAX_SESSIONS` | `8` | how many live sessions may exist at once. Each holds an upstream session that is billed while it lives, and eight tabs is eight of them |
| `MAX_SESSIONS_PER_ADDRESS` | `4` | the same, per client address. Bound to loopback the two coincide; they stop coinciding the moment `BIND_IP` opens |
| `MAX_TICKETS_PER_ADDRESS` | `150` | how many upgrade tickets one address may hold at once. On loopback that is one person; **behind a NAT or a reverse proxy it is everyone**, and then this — not `MAX_SESSIONS` — is what caps concurrent users. A load test found this the hard way: 50 clients, `MAX_SESSIONS=100`, and 28 refusals, all at the ticket desk. **The global bound is derived at 2×**, so the two cannot be raised out of step — at that ratio a third busy address evicts the first one's live tickets, which is the number to check before raising this in a deployment with many distinct clients |
| `ALLOWED_ORIGINS` | — | extra origins allowed to open `/ws`, comma separated, exact `scheme://host:port`. Loopback is always allowed on any port and needs no listing |
| `TURN_DETECTION` | `manual` | `manual` or `server` — who decides your turn ended. `manual` measured 833 ms faster on xAI and trades that against false turns. Gemini ignores it |
| `FRAME_SAMPLES` | `1600` | mic batch size in 16 kHz samples; `1600` = 100 ms. Reaches the browser's AudioWorklet through `GET /config.json`. `160..16000` |

`SILENCE_DURATION_MS`, `FRAME_SAMPLES` and `TURN_DETECTION` are the latency knobs, and `priv/spike/latency_bench.exs` measures what moving them buys. Both fall back **loudly**: `SILENCE_DURATION_MS=30O` (letter O) warns at boot rather than silently reverting to the default and invalidating the next benchmark run.

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

The BEAM needs no reader task and no receive loop: the socket process *is* both directions. `handle_in/2` is upstream, `handle_info/2` is downstream, and the provider session is a linked GenServer pushing into our mailbox.

`LiveCeci.Application` starts exactly one child — `{Bandit, plug: LiveCeci.Router, port: port}`. Bandit supervises the per-connection processes, so there is no hand-rolled supervision tree to get wrong.

## The module that matters, and the seam under it

[`LiveCeci.Socket`](lib/live_ceci/socket.ex) is the whole app: one browser socket in, one model session out, and everything that makes Ceci *Ceci* layered on top of that single bridge.

The primitive underneath is four steps — open a session, send the mic up, receive voice back, push it to the browser. `Socket` adds the persona, the tools, transcription, and `Process.flag(:trap_exit, true)`, so a session crash becomes an `{:EXIT, …}` message it can report instead of a silent death.

What it does *not* do any more is know which API answered. [`LiveCeci.Provider`](lib/live_ceci/provider.ex) is a behaviour over six neutral events:

```
{:voice, pcm}   :interrupted   {:transcript, :user | :ceci, text}
{:action, cmd}  {:error, _}    {:closed, _}
```

The two wire formats disagree about nearly everything — Gemini pushes typed structs through callbacks and takes audio by reference; xAI speaks a JSON event protocol and takes raw binary frames — so neither vocabulary makes a good lingua franca. Providers translate into the set above, and decoding is theirs: by the time a frame reaches the socket it is PCM, not base64 and not a struct.

The behaviour has no `send_tool_result/3`, and that omission is load-bearing. `gemini_ex` wants a tool result as the callback's **return value**, synchronously, while the model's voice is paused; xAI wants two separate messages. No single signature fits both without being dead weight in one, so each provider dispatches through `LiveCeci.Tools` itself. The decision stays shared; only the handshake differs.

## The two traps

**Mic audio goes to `send_realtime_input`, not `send_client_content`** — the one in [`LiveCeci.Socket`](lib/live_ceci/socket.ex). `send_client_content` is for seeding history before the conversation; point the mic at it and the live turn never fires, so you get dead air.

**Live function calls are synchronous** — the rule that governs [`LiveCeci.Tools`](lib/live_ceci/tools.ex). The model's voice is paused until your tool returns, so `dispatch/2` is a plain function over plain data: no GenServer call, no HTTP, no `Task.await`. It decides an action, hands it to the socket process, and answers the model in the same breath. `test/live_ceci/tools_test.exs` fails if one starts doing real work — which matters more now that the tools are called `agendar_sessao` and `emitir_recibo` and *sound* like they should hit a database.

And one bug this design cannot express: a per-turn generator that has to be re-entered in an outer loop — answer one sentence, then silence forever. There is no equivalent here. The provider session *pushes* every server message into the socket's mailbox, so there is no iteration to forget to restart.

## Why no Phoenix

The wire contract here is **raw binary PCM frames**. Phoenix Channels would only wrap them in a JSON envelope, and LiveView can't own the audio path anyway — mic worklet and PCM playback are necessarily JS. So: `Bandit` + `Plug` + `WebSockAdapter.upgrade/4`, which is smaller and a closer match to what the app does.

Phoenix earns its place at the *next* step — multi-user, auth, Presence, deploy, a server-rendered UI. Then mount this same `WebSock` handler in a Phoenix router and let LiveView drive only the chrome.

## What's inside

| | |
|---|---|
| `lib/live_ceci.ex` | `config/0` — the resolved model, voice, and port |
| `lib/live_ceci/application.ex` | starts the ticket store, the session cap, and Bandit — in that order, because an upgrade arriving before the first two would crash on them |
| `lib/live_ceci/socket.ex` | the bridge — provider-agnostic, six events wide |
| `lib/live_ceci/provider.ex` | the behaviour, and why it has no `send_tool_result/3` |
| `lib/live_ceci/provider/gemini.ex` | Gemini Live, through `gemini_ex` |
| `lib/live_ceci/provider/grok.ex` | xAI's Voice Agent, hand-rolled on `websockex` — no Elixir package speaks the OpenAI Realtime protocol |
| `lib/live_ceci/live_session.ex` | the process that carries mic audio to Gemini **so the socket does not** — `gemini_ex` has no cast path, so the blocking call had to move rather than disappear, and the queue is bounded |
| `priv/spike/grok_voice_spike.exs` | the throwaway script that verified the xAI protocol against the live API before any of it was written — including whether manual turn detection beats server VAD |
| `priv/spike/latency_bench.exs` | TTFA, both backends, interleaved — see [Measuring latency](#measuring-latency) |
| `priv/spike/load_test.exs` | 50 concurrent sessions against a stub provider — see [Load](#load) |
| `lib/live_ceci/tools.ex` | `agendar_sessao` / `confirmar_presenca` / `emitir_recibo` / `resumo_mensal` — stubs that return **instantly**, so the voice never stalls, with the operational-only boundary enforced in the parameter schemas rather than only in the prompt |
| `lib/live_ceci/persona.ex` · `priv/assets/ceci_persona.txt` | who Ceci is — read at **compile time**, with `@external_resource` so editing the text triggers a recompile |
| `lib/live_ceci/sessions.ex` | the cap on concurrent sessions — a GenServer, because deciding correctly under contention means deciding one at a time |
| `lib/live_ceci/tickets.ex` | single-use tickets for the upgrade — the browser's `new WebSocket(url)` takes no headers, so the credential cannot ride on the upgrade itself |
| `lib/live_ceci/redact.ex` | `inspect/1` for anything a provider touched — both APIs echo the key back, one in its URL and one in its error text |
| `lib/live_ceci/router.ex` | the whole HTTP surface: the upgrade behind an `Origin` check, a capacity check and a ticket; the ticket mint; static files; `/healthz`; `/config.json` |
| `config/runtime.exs` | the `.env` reader, the API-key aliasing, and every knob above — refuses to read `.env` at all in `:test` |
| `.tool-versions` · `.github/workflows/ci.yml` | what this is built with, and the gate that checks it — compile, format, test, both audits, and a compile-cycle check |
| `priv/frontend/` | the browser client: mic worklet, voice playback, transcript, and the activity panel |

Dependencies, in full: `bandit`, `plug`, `websock_adapter`, `websockex`, `gemini_ex`, `jason`, plus `mix_audit` in dev/test. That's the list.

`gemini_ex` is pinned to the minor (`~> 0.17.0`, not `~> 0.17`). It is a 0.x library that has already moved the Live WebSocket transport once in a minor release, `LiveCeci.Provider.Gemini` pattern-matches its structs in function heads, and `LiveCeci.LiveSession` calls one of its internal messages directly — so drift surfaces as a runtime error, not a compile one.

## The HTTP surface

| Route | |
|---|---|
| `GET /` · `GET /main.js` · `GET /pcm-processor.js` | the client, served from `priv/frontend` |
| `GET /healthz` | `200 ok` |
| `GET /config.json` | `{"frameSamples":N,"silenceMs":N}` — the only channel between `.env` and the AudioWorklet that applies them |
| `POST /ws-ticket` | mints a single-use, 30 s, address-bound ticket. Same `Origin` check as `/ws` — an endpoint that mints what `/ws` demands is worth exactly the check in front of it |
| `GET /ws` | the WebSocket upgrade — 60 s timeout, 1 MB max frame. Three checks in order: **`Origin`** (loopback on any port, plus `ALLOWED_ORIGINS`), then **capacity**, then the **ticket**. A bad or missing origin or ticket is `403`; at capacity it is `503`, and the ticket is deliberately **not** spent — it stays valid for when a slot frees |

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

### Both xAI levers, measured — 2026-08-29

Probe 10 of `priv/spike/grok_voice_spike.exs` runs the same utterance through four
session configurations, three reps each, interleaved:

| config | median | reps |
|---|---:|---|
| baseline (`server_vad`) | 1818 ms | 1717, 1818, 1919 |
| `reasoning.effort: "none"` | 1818 ms | 1818, 1818, 1919 |
| manual turns | 1100 ms | 1014, 1100, 1112 |
| manual + `effort: "none"` | **985 ms** | 958, 985, 1186 |

**`reasoning.effort` does nothing.** Identical median, overlapping ranges. It had been
called "the obvious suspect" for the 1016 ms of generation in the study above; it is
not, and this is what refuting it looks like.

**Manual turns are worth 833 ms**, consistently — the manual maximum (1112 ms) sits
below the baseline minimum (1717 ms). Now the default, with `TURN_DETECTION=server` as
the way back.

One measurement caveat: the `server_vad` rows are quantised in ~101 ms steps because the
probe only polls between 100 ms padding sends, so they are overstated by 0-100 ms. The
gap is eight times that, so the conclusion holds.

What it costs: the browser's gate is now the thing that decides you finished a sentence,
and it can be wrong. `idle_timeout_ms` lives inside the `turn_detection` this mode turns
off, so there is no server-side net either — the worklet carries a 30 s max-utterance
guard instead.

## Load

```bash
LOAD_CLIENTS=50 LOAD_SECONDS=30 mix run --no-start priv/spike/load_test.exs
```

Real Bandit, real WebSockets, real tickets, real caps, real audio frames at the ten per
second a browser sends. The provider is the one fake part, deliberately: fifty real
sessions would cost money and would measure xAI's capacity rather than this server's.
The stub echoes each mic frame back as voice, so the downstream push and the shedding
are exercised too.

Ramped until something gave:

| clients | connected | frames up/down | KB per session |
|---:|---:|---|---:|
| 100 | 100/100 | 10k / 10k | 43.7 |
| 400 | 400/400 | 40k / 40k | 17.0 |
| 1000 | 1000/1000 | 100k / 100k | 12.9 |
| 2000 | 2000/2000 | 200k / 200k | 9.0 |
| 5000 | 4455/5000 | 356k / 356k | 6.1 |

**Not one frame was dropped at any level**, including the one with refusals, and no
process leaked at any level. Cost per session *falls* with scale — 43.7 KB to 6.1 KB —
as the VM's fixed cost spreads.

The 5000 run is the only one that refused anything, and the refusals are not this
server: 544 of 545 were `WebSockex.ConnError`, i.e. the TCP connect. The accept backlog
looked like the answer — ThousandIsland defaults to 1024 — but raising it to 16384 made
it *worse*, 1155 refusals against 545. A real limit refuses a consistent number; that is
noise. Past roughly 4000 clients this harness measures itself: client and server share
one BEAM and one machine.

So the honest statement is that **the ceiling was not found**, not that it is 4455.

Nothing dropped either way, no backpressure fired, nothing leaked. At 59.5 KB a session
a gigabyte holds roughly seventeen thousand of them — this server is not the ceiling.

The run before that one is why `MAX_TICKETS_PER_ADDRESS` exists: 22 of 50 connected with
`MAX_SESSIONS` at 100, and every refusal was at the per-address ticket cap rather than
the session cap the run was set up to test. It was a hardcoded 20.

**What it does not measure**, so nobody reads more into it: provider latency, which the
985/1220 ms above dominates anyway; the providers' own concurrency limits, which remain
the real and unknown ceiling; and TLS, since all of this is loopback.

## The WebSocket contract

`WS /ws` — the whole contract.

- **Browser → server:** binary frames, 16 kHz mono PCM s16le, plus one JSON text frame: `{"type":"end_of_speech"}`, sent when the client's own gate decides the sentence ended. Any other text frame is dropped. It is sent unconditionally — under `TURN_DETECTION=server` the provider ignores it, so neither end has to know the mode.
- **Server → browser:** binary frames of 24 kHz PCM (voice), plus JSON text frames:
  `{"type":"transcript","role":"user"|"ceci","text":…}` ·
  `{"type":"action","action":"agendar"|"presenca"|"recibo"|"resumo","detail":…}` ·
  `{"type":"interrupted"}` · `{"type":"error","message":…}`

Empty transcripts are dropped rather than drawn as blank lines, and a text-only model part pushes nothing — this agent speaks, it does not type.

## Tests

```bash
mix test
mix format --check-formatted
mix deps.audit          # advisory database; mix hex.audit only reads retirement flags
```

**185 tests, no network:**

| | |
|---|---|
| `provider/grok_test.exs` (41) | xAI events in, neutral events out — binary voice and the base64 fallback, barge-in, transcripts, tool dispatch, the two-message turn commit, the session shape in both turn modes, and that mic frames go out by `cast` so a slow upstream never holds the socket |
| `provider/gemini_test.exs` (25) | real `gemini_ex` structs in, neutral events out, plus the session options the API actually reads and the `connect` failure that used to leave a billed session behind |
| `router_test.exs` (21) | the whole HTTP surface: the `Origin` check against real hostile origins, tickets that work exactly once and only from the address they were minted for, the capacity refusal that does **not** spend the ticket, the security headers, and that nothing under `/assets` is reachable |
| `tools_test.exs` (19) | dispatch, the four declarations, the instant-return guardrail — measured twice, because wall clock catches blocking and reductions catch work — that no tool declares a parameter clinical content could hide in, and that cost does not grow with what the model sends |
| `socket_test.exs` (16) | the bridge at the message-translation level, mentioning neither vendor: neutral events in, real WebSocket frames out, and the one text frame the browser sends |
| `live_ceci_test.exs` (14) | `config/0` reads at call time, `pt_BR` normalises to `pt-BR`, `env_int/3` falls back **loudly** on every plausible `.env` typo, and the test environment is sealed from both `.env` and the shell |
| `redact_test.exs` (9) | the four shapes that actually leaked a key into a log, the two passes that catch them, what redaction must **not** eat — and that no `Logger` call in `lib/` inspects anything itself |
| `tickets_test.exs` (9) | single use under eight-way contention, address binding, expiry against a negative monotonic clock, and that one address cannot lock everyone else out |
| `sessions_test.exs` (6) | the cap, per-address, release on a brutal kill with no cleanup running, exactly five accepted out of forty concurrent joins, and the upstream closed when a connection dies badly |
| `live_session_test.exs` (6) | the carrier never blocks its caller, its queue is bounded, and a test that reads the installed `gemini_ex` to check the internal message it depends on is still there |
| `socket_lifecycle_test.exs` (6) | the socket opened and closed for real over TCP, so `terminate/2` actually runs — the path that leaked billed provider sessions when it did not |
| `agent_name_test.exs` (5) | the agent is Ceci, in the instruction, in the `:ceci` atom, in the `"ceci"` role on the wire, and nowhere in `lib/` or `priv/frontend` under the old name |
| `persona_test.exs` (5) | the instruction loads, carries who she is / what she will not touch / that she is live, and names every callable tool |
| `application_test.exs` (3) | one listener, bound to loopback, with everything it depends on started before it — and a killed child coming back |

Real `gemini_ex` structs in, real WebSocket frames out. `config/test.exs` sets a dummy API key so config validation passes without one.

## Notes

- **Voice** is whatever the chosen backend offers — `GROK_LIVE_VOICE` (default `eve`) or `GOOGLE_LIVE_VOICE` (default `Aoede`). Each API has its own voice set, so neither can reproduce a TTS voice you used elsewhere. The persona carries the character, not the timbre.
- **Barge-in** is client-side: the browser cuts playback the instant the mic hears you (RMS gate at `0.04` in `priv/frontend/main.js`). It was `0.02`, which room noise crossed at 0.021-0.023 and used to cut her off mid-word; a deliberate interruption reads 0.054. The server forwards `interrupted` too.
- **The end of your turn** is decided by that same gate under `TURN_DETECTION=manual`, on the falling edge, spending the same silence budget the server VAD would have. Worth 833 ms, and it moves the false-turn risk from the provider to the browser. `idle_timeout_ms` lives inside the `turn_detection` this mode switches off, so there is no server-side safety net either — the worklet carries a 30 s max-utterance guard instead.
- **Mic framing.** The worklet batches PCM into ~100 ms frames rather than emitting one per 128-sample render quantum — at 48 kHz that was 375 WebSocket frames/sec of ~85 bytes, where framing overhead dwarfed the audio. Barge-in can't wait for the batch, so a quantum that crosses the gate posts an RMS-only message immediately and the cut stays instant.
- **The activity panel** is the browser's only proof the round trip closed: her voice says she booked it, the panel says the tool call actually came back.
- **Concurrency** is where the BEAM pays off: each listener is an isolated, supervised process, so one dropped call never touches another. The failure this avoids is a single process holding N sessions and saturating.
