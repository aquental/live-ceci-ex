# Project Health — live-dj

**Date**: 2026-08-28 (second audit of the day; the pre-cleanup run is archived under `.claude/audit/archive/2026-08-28-pre-cleanup/`)
**Scope**: full project, 5 parallel specialist auditors + consolidation
**Commit baseline**: `3017a3c` plus an uncommitted working tree (16 files)

---

## Executive summary

**Grade: C (57/100 weighted).** The app is structurally excellent and operationally
unsafe. Those two facts are independent and both are load-bearing.

Architecture and dependencies are in very good shape: six modules, zero compile-time
cycles, one supervised child, every dependency current and audit-clean. Nothing here
needs restructuring.

What blocks a deployment is entirely in two places — the front door (`router.ex`'s
`/ws`) and the audio hot path (`socket.ex`). Six P1s across security and performance,
all of them local fixes, none requiring an architectural change.

One correction to the record: earlier in this session the missing `Origin` check was
described as "deploy-gated, only matters beyond localhost". **That was wrong.**
Cross-site WebSocket hijacking works *because* the target is localhost — any page the
developer visits can open `ws://localhost:8000/ws`. Demonstrated live against a
running instance: a handshake carrying `Origin: https://evil.example` returned
`HTTP/1.1 101 Switching Protocols`.

---

## Scores

Re-based for a non-Phoenix OTP app. Criteria for migrations, N+1 queries, LiveView
authorization, changeset handling and `sobelow` were **excluded as inapplicable**, not
scored as failures — this project has no database, no Ecto and no Phoenix.

| Category | Score | Grade | Why |
|---|---:|:---:|---|
| Architecture | 90 | A | 6 modules, 0 xref cycles, 0 compile-time edges, sound supervision. One config-read duplication (P3). |
| Dependencies | 92 | A | All 6 direct deps current; `mix deps.audit` and `mix hex.audit` both clean. `websock` used directly but declared only transitively. |
| Test quality | 80 | B | 49 tests, no flakes, clean async discipline. Two P1 coverage gaps on the socket's binary path and `init/1`. |
| Performance | 20 | F | Two P1s in the voice path: unbounded downstream mailbox, and head-of-line blocking on the mic path. |
| Security | 5 | F | Three P1s: no `Origin` check, no auth or session cap, and API key reaching the application log. |

Per Iron Law 3 these are a within-project baseline for tracking trends, not a
cross-project comparison. The two F grades mean "not deployable as it stands" — they
do not mean the code is badly written.

---

## P1 findings

### S1 — Cross-site WebSocket hijacking · `router.ex:24-28`
No `Origin` validation before upgrade. Any page the developer visits opens a billed
Gemini session on their instance. **Verified live**: `Origin: https://evil.example`
→ `101 Switching Protocols`. Applies on localhost, today.

### S2 — No auth, no connection cap, no session lifetime · `router.ex:24-28`, `socket.ex:42-86`
`init/1` opens a paid upstream session per socket, unconditionally. N sockets = N
billed sessions. The 60 s timeout is *idle*-only, so one byte every 30 s holds a
session open forever. Financial DoS plus Google-side quota exhaustion.

### S3 — API key reaches the application log · `socket.ex:80, 102, 136, 141, 146, 151, 157`
`gemini_ex` builds the Live WebSocket URL as `...?key=<redacted>`
(`deps/gemini_ex/lib/gemini/client/websocket.ex:553`), so upstream failure reasons
carry key material. All seven sites log `inspect(reason)` verbatim. Reproducible from
the suite's own output: `mix test` prints
`[error] Live session error: {:http_error, 403, "API key not valid: <redacted>"}`.

**Correlation worth recording**: the fix applied earlier today stopped the reason
reaching the *browser* (`error_frame/1` discards it) but the same value still reaches
the *log*. The fix was correct and incomplete.

### P1 — Unbounded downstream mailbox · `socket.ex:116-133`
`gemini_ex` pushes voice via bare `send/2` with no backpressure, and the socket
process is the only consumer of the mailbox it is filling. ThousandIsland's default
`send_timeout: 30_000` is not overridden, so a wedged browser parks the process for
30 s while ≥64 KB/s queues — roughly 1.9 MB per connection, uncapped and unlogged.

### P2 — Head-of-line blocking on the mic path · `socket.ex:97`, `live_session.ex:24`
The mic path is two synchronous hops, not one: `GenServer.call` → Session →
`WebSockex.send_frame`, itself a `:gen.call` with a 5 s default. Lowering
`@send_timeout` alone does not help, because `handle_in/2` retries on the very next
frame; the socket stays blocked ~100 % of a wedge either way. The fix needs a hold-off
in state, not just a shorter timeout.

---

## P2 findings

- **Unvalidated binary pass-through** (`socket.ex:91-105`) — arbitrary bytes forwarded
  upstream labelled as PCM. `max_frame_size: 1_000_000` is ~300× the 3,200-byte
  legitimate frame.
- **Barge-in gate is level-triggered** (`pcm-processor.js:50`) — posts on every quantum
  above threshold rather than on crossing it: ~375 messages/sec during speech. This
  undercuts the 100 ms batching introduced in the same file earlier today, which cut
  data volume 37.5× but left message count during speech unchanged.
- **Per-quantum allocation on the audio render thread** (`pcm-processor.js:28`) — a
  growing `Array` 375×/sec where a GC pause is an audible dropout.
- **DOM reflow per transcript fragment** (`main.js:25-32`) — `on_transcription` fires
  per chunk, not per turn, so `scrollTop = scrollHeight` forces layout on every
  fragment.
- **Nothing released on close, and no reconnect** (`main.js:85, 116`) — mic,
  AudioContext and worklet run forever after the socket closes. `onclose` sets the text
  "tap to reconnect", but the button was disabled at `:116` and is never re-enabled, so
  tapping does nothing. **Verified.**
- **Test gaps** — `handle_in/2` for `opcode: :binary` (the mic path) and `Socket.init/1`
  are both uncovered. **Verified**: `socket_test.exs` exercises `opcode: :text` only,
  and never calls `init/1`. This means today's error-frame fix is regression-tested on
  the `handle_info` path but not the `init/1` path.
- **gemini_ex private-message coupling is untested** — `live_session.ex` calls the
  internal `{:send_realtime_input, opts}` message. `live_session_test.exs` asserts
  against a hand-written stub, so the stub *is* the contract; a `0.17.1` that renames
  the message keeps compile clean and all 49 tests green, surfacing only as per-frame
  errors in production.

---

## P3 findings

`String.to_atom/1` in `tools.ex:77` (raised independently by three auditors and cleared
by all three — both call sites pass literals; hygiene, not a vulnerability) ·
`max_frame_size` 1 MB → 64 KB · `only:` allowlist on the second `Plug.Static` ·
`application.ex:9` reads `:port` directly instead of via `LiveDJ.config/0` · `websock`
missing as a direct dep · `websock_adapter` declared `~> 0.5` but locked at `0.6.0` ·
no `.tool-versions` and no CI (built and tested only on Elixir 1.20.3 / OTP 29 while
`mix.exs` declares `~> 1.17`) · `.dockerignore` present with no `Dockerfile` ·
security headers (CSP, X-Content-Type-Options, referrer-policy).

---

## Action plan

**Immediate** — before this is exposed to anything, including a browser session on the
developer's own machine:
1. `Origin` allowlist on `/ws` (S1). Smallest fix with the largest effect.
2. Redact `inspect(reason)` at all seven `socket.ex` sites (S3).
3. Connection cap and max session lifetime (S2).

**Short term** — before it is usable on a real network:
4. Mailbox shedding + `send_timeout: 2_000` + `:off_heap` process flags (P1).
5. Hold-off after a send timeout, not just a shorter timeout (P2).
6. Tests for `handle_in/2` binary and `Socket.init/1`.
7. Edge-trigger the barge-in gate and remove the per-quantum allocation.

**Long term**:
8. `teardown()` on close and a working reconnect path.
9. Canary test for the `gemini_ex` private-message coupling.
10. Toolchain pin and CI.

---

## Verified clean

`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test` (49
passed), `mix hex.audit`, `mix deps.audit`, `mix xref graph` (0 cycles). `.env` was
never committed (`git log --all --full-history --diff-filter=A -- .env` is empty) and
is gitignored at `.gitignore:14`. `priv/assets/mira_persona.txt` is unreachable over
HTTP — confirmed against a live server, not only in tests. `persona.ex` is
compile-time. `dispatch/2` is pure. No key material appears in any file under
`.claude/audit/`.
