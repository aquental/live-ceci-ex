# live-dj-ex — a voice agent you can interrupt, in Elixir

Talk to **Mira**, a late-night radio DJ. Ask her to play something. Talk over her mid-sentence and she stops, listens, and picks the thread back up.

An Elixir port of [`live-dj`](../live-dj) — the demo from **EP1 of the Multimodal Agents Cookbook**. Built on the **Gemini Live API** via [`gemini_ex`](https://hex.pm/packages/gemini_ex), with **no Phoenix and no agent framework**, so the whole primitive stays visible.

## Run it

```bash
cp .env.example .env          # paste your GOOGLE_API_KEY (Gemini Developer API / AI Studio, not Vertex)
mix deps.get

mix run --no-halt                          # the full DJ
SOCKET_HANDLER=minimal mix run --no-halt   # just the ~30-line primitive
```

Open <http://localhost:8000>, **put headphones on** (otherwise she hears her own radio), tap 🎙 and talk.

Try: *"hey Mira"* · *"can you play something dream pop"* · *"skip this"* — then **talk over her** while she's speaking.

## How it works

The browser owns the audio (mic worklet down to 16 kHz, 24 kHz playback, barge-in). The server owns the socket. The model owns the turn.

```
Browser ──ws──> Bandit ──> LiveDJ.Socket          (one process per browser)
                              │  send_realtime_input/2
                              ▼
                           Gemini.Live.Session    (linked GenServer)
                              │  callbacks -> send(owner, msg)
                              ▼
                           handle_info/2 ──> binary voice + JSON to the browser
```

Where the Python version runs **two asyncio tasks** (mic up, audio down), the BEAM needs neither: the socket process *is* both directions. `handle_in/2` is upstream, `handle_info/2` is downstream, and the Live session is a linked GenServer pushing into our mailbox.

## The two modules that matter

| Module | What it is |
|---|---|
| [`LiveDJ.Minimal`](lib/live_dj/minimal.ex) | The entire primitive: open a session, send the mic, receive voice, play it. Nothing else. |
| [`LiveDJ.Socket`](lib/live_dj/socket.ex) | The full app — the same bridge plus Mira's persona, music tools, transcripts, and barge-in. |

Start with the minimal one. Everything that makes Mira *Mira* is the difference between those two files.

## The gotcha — and the one that vanished

The Python original exists to teach a bug: `session.receive()` is a **per-turn** async generator, so a naive `async for` makes the agent answer one sentence and go silent forever. It needs an outer `while True`.

**That bug cannot be written in Elixir.** `Gemini.Live.Session` is a GenServer that *pushes* every server message through callbacks — there is no generator to exhaust and no loop to forget to restart. The actor model deletes the entire class of bug, which is good engineering and a worse demo.

Its sibling **does** survive, in [`LiveDJ.Gotcha`](lib/live_dj/gotcha.ex): mic audio goes to `send_realtime_input`, **not** `send_client_content` — get that wrong and the model simply never hears you.

And the rule that governs [`LiveDJ.Tools`](lib/live_dj/tools.ex): live function calls are **synchronous**, so the model's voice is paused until your tool returns. Every handler decides a command and returns instantly, never awaiting playback. `test/live_dj/tools_test.exs` fails if one starts doing real work.

## Why no Phoenix

The wire contract here is **raw binary PCM frames**. Phoenix Channels would only wrap them in a JSON envelope, and LiveView can't own the audio path anyway — mic worklet and PCM playback are necessarily JS. So: `Bandit` + `Plug` + `WebSockAdapter.upgrade/4`, which is smaller and a closer match to what the app does.

Phoenix earns its place at the *next* step — multi-user, auth, Presence, deploy, a server-rendered UI. Then mount this same `WebSock` handler in a Phoenix router and let LiveView drive only the chrome.

## What's inside

| | |
|---|---|
| `lib/live_dj/socket.ex` | the Gemini Live bridge + music-tool dispatch |
| `lib/live_dj/minimal.ex` | the ~30-line voice-only extract |
| `lib/live_dj/tools.ex` | `play_playlist` / `play_track` / `skip` / `pause` — they return **instantly**, so the voice never stalls |
| `lib/live_dj/persona.ex` · `priv/assets/mira_persona.txt` | who Mira is |
| `lib/live_dj/gotcha.ex` | the wrong-way/right-way example |
| `lib/live_dj/router.ex` | the WebSocket upgrade + static files |
| `priv/frontend/` | the browser client, **copied unchanged** from the Python repo |
| `priv/assets/tracks/` | four dream-pop tracks |

The frontend is byte-identical to the Python original: the WebSocket contract did not change, so nothing needed porting.

## The WebSocket contract

`WS /ws` — unchanged from the Python server.

- **Browser → server:** binary frames, 16 kHz mono PCM s16le.
- **Server → browser:** binary frames of 24 kHz PCM (voice), plus JSON text frames:
  `{"type":"transcript","role":"user"|"mira","text":…}` ·
  `{"type":"play","action":"playlist"|"track"|"skip"|"pause","value":…}` ·
  `{"type":"interrupted"}` · `{"type":"error","message":…}`

## Tests

```bash
mix test
```

35 tests, no network: `Tools` dispatch and the instant-return guardrail, `Persona` loading, and the whole bridge exercised at the message-translation level — real `gemini_ex` structs in, real WebSocket frames out.

## Notes

- **Voice** is a Gemini Live *native* voice (`LIVE_VOICE`, default `Aoede`) — the Live API has its own voice set, so it can't reproduce a TTS voice you used elsewhere. The persona carries the character, not the timbre.
- **Barge-in** is client-side: the browser cuts playback the instant the mic hears you (RMS gate in `priv/frontend/main.js`). The server forwards `interrupted` too.
- **Concurrency** is where the port pays off. The Python design doc lists *"what breaks at 10× concurrent: one process holding N sessions saturates."* Here each listener is an isolated, supervised process; one dropped call never touches another.
