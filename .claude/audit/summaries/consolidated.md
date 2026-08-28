# Consolidated Audit Summary — live-dj

**Date**: 2026-08-28
**Strategy**: Compress (12.6k input tokens → ~5.2k output)
**Input**: 5 files (arch-review, security-audit, perf-audit, test-audit, deps-audit)

---

## Executive Summary

**Critical Status**: 3 security P1s + 2 performance P1s block production deployment.

The app is structurally sound (zero compile-time cycles, clean module boundaries) but has two categories of critical-path failures. **Security**: `/ws` is an unauthenticated, unmetered gateway to the Gemini API with cross-site hijacking and API-key-in-logs exposure. **Performance**: unbounded downstream mailbox and head-of-line blocking cause 30-second stalls and 2 MB queue buildup on poor networks. All fixes are documented and scoped; none require architectural changes.

---

## Critical Findings (P1)

### Security — 3 P1 Issues

**P1 — Cross-Site WebSocket Hijacking (no Origin validation)**  
*Location*: `lib/live_dj/router.ex:24-28`

The `/ws` endpoint accepts connections from any origin — `new WebSocket("ws://localhost:8000/ws")` from any website silently opens a paid Gemini session. Fix: reject unknown origins before upgrade (security-audit.md:42-56).

**P1 — Unauthenticated, uncapped session fan-out**  
*Location*: `lib/live_dj/router.ex:24-28` (no auth), `lib/live_dj/socket.ex:42-86` (unconditional session start)

Every HTTP request opens a billed Gemini Live session with no ticket, token, or concurrency cap. A trivial script opens 5,000 sockets; the server opens 5,000 paid upstream sessions. Fixes: single-use ticket, global+per-IP session cap, max session lifetime (security-audit.md:88-122).

**P1 — API keys leak to application logs** *(Verified finding, in scope)*  
*Location*: `lib/live_dj/socket.ex:80, 102, 136, 141, 146, 151, 157` (seven `inspect(reason)` sites)

`gemini_ex` embeds the API key in the Live WebSocket URL query string. Upstream failure reasons carry that URL. Browser-facing leak is fixed (error_frame/1 discards the reason), but the same value still reaches production logs verbatim: `[error] Live session error: {:http_error, 403, "API key not valid: <redacted>"}`. 

**Correlation**: the fix applied today blocked the browser vector but missed the log vector. Fix: apply redaction helper to all six `inspect(reason)` call sites (security-audit.md:235-242). Recommendation: P1 critical.

### Performance — 2 P1 Issues

**P1 — Unbounded downstream mailbox: ~2 MB queues, 30 s stalls**  
*Location*: `lib/live_dj/socket.ex:116-133`

`gemini_ex` sends voice at ≥64 KB/s to the socket process via bare `send/2` with no backpressure. If the browser's receive window closes (slow network, throttled tab), the TCP write blocks for up to 30 seconds — and the socket process is also the only mailbox consumer, so it deadlocks. 30 s × 64 KB/s ≈ 1.9 MB of unread binaries on the heap. Fixes: 2 s write timeout on `ThousandIsland` transport, `message_queue_data: :off_heap` + `fullsweep_after: 10` process flags, shed voice frames when mailbox exceeds 40 messages (perf-audit.md:58-96).

**P1 — Head-of-line blocking: 100% socket blocked during upstream stalls**  
*Location*: `lib/live_dj/socket.ex:97`, `lib/live_dj/live_session.ex:24, 33-37`

Upstream chain: socket → GenServer.call(1s) → Session GenServer → gen.call(5s) → WebSockex → TLS. WebSockex timeout is 5 s by default, nested inside `Session` GenServer.handle_call. A stalled TLS write wedges the Session for the full 5 s, and socket retries unconditionally every `@send_timeout` (1 s), blocking on each call — 100% socket blocked for 5 s. Downstream voice (Mira's response) queues and goes silent. Fixes: shorten `@send_timeout` to 250 ms, add 1 s hold-off after error to stop retrying during wedge (perf-audit.md:138-162).

---

## Important Findings (P2)

### Security — 1 P2 Issue

**P2 — Unvalidated, unmetered binary pass-through**  
*Location*: `lib/live_dj/socket.ex:91-105`, frame ceiling at `lib/live_dj/router.ex:26`

`handle_in/2` forwards browser frames directly to the upstream API without checking they are valid s16le PCM or rate-limited. `max_frame_size: 1_000_000` allows 1 MB frames where the protocol sends ~3.2 KB. Fix: drop to 64 KB, validate even-byte length, add token bucket rate limit (security-audit.md:151-174, perf-audit.md:423-435).

### Performance — 3 P2 Issues

**P2 — Barge-in posts 375 msg/sec instead of 1 per utterance**  
*Location*: `priv/frontend/pcm-processor.js:50`

AudioWorklet runs `process()` 375 times/sec at 48 kHz. Barge-in gate is level-triggered (every quantum above threshold), not edge-triggered, flooding the MessagePort with 375 RMS-only messages/sec during speech. Main thread scheduled to decode audio and run DOM work. Fix: edge-trigger and let main thread signal to worklet when listening (perf-audit.md:206-227).

**P2 — Per-quantum heap allocation on audio render thread**  
*Location*: `priv/frontend/pcm-processor.js:28-33`

Fresh JS Array allocated 375/sec, grown via `push`. Runs on audio render thread; GC pause is audible dropout. Rule: `process()` allocates nothing. Fix: preallocated scratch buffer, one fused loop, bitwise truncation instead of Math.floor (perf-audit.md:251-276).

**P2 — One DOM reflow per Gemini fragment, not per turn**  
*Location*: `priv/frontend/main.js:25-32`

`on_transcription` fires per audio chunk (~24 kHz rate), not per turn. Browser creates new `<div>`, appends, reads `scrollHeight` (forced sync layout), removes old divs. ~60 reflows/sec on main thread. Fix: coalesce fragments into current line instead of new div, batch scroll to one rAF per audio frame (perf-audit.md:304-321).

**P2 — Resources not released on socket close**  
*Location*: `priv/frontend/main.js:85, 96-113`

`ws.onclose` releases nothing. Microphone stream stays recording, AudioContext and worklet run forever (375 process/sec), burned CPU discarded. Reconnect button never re-enables. Fix: `teardown()` stops tracks, closes context, disconnects worklet; re-enable "talk" button (perf-audit.md:350-366).

### Test Quality — 2 P2 Coverage Gaps

- **socket.handle_in binary path** (critical ingestion): zero coverage; add tests for `:ok` and `{:error, _}` branches
- **socket.init/1 session startup**: never invoked; covers init-failure branch of `error_frame/1` and session open error handling
- **terminate/2 cleanup**: both clauses untested; verify session.close is called and nil-session is safe
- **Malformed WebSocket handshake**: no test for bad upgrade headers; if WebSockAdapter starts crashing, nothing catches it

---

## Cross-Category Correlations

1. **Security P1 (API key logs) ↔ Perf P1 (mailbox)**  
   Increased logging from hot mailbox amplifies key leakage. Redaction helps both.

2. **Perf P1 (HOL blocking) ↔ Socket concentration**  
   Architecture cleared socket's 209-line concentration as justified (one WebSock behaviour for one concern). P1 is not a split candidate; it is a timeout + hold-off issue.

3. **Security P2 (frame validation) ↔ Perf P3 (max_frame_size)**  
   Both agents independently recommended dropping `max_frame_size` from 1 MB to ~64 KB. **Single recommendation**: 64_000 (allows 20× headroom for jitter batching).

---

## Deduplicated Findings (Reported by 2+ Agents)

**`String.to_atom/1` at `lib/live_dj/tools.ex:77`**  
**Agents**: architecture, security, performance  
**Verdict**: NOT exploitable — both call sites pass literals ("mood", "title"). No atom-exhaustion path. Flagged by all three as hygiene nit (loaded footgun one refactor away). **Action**: replace with `@arg_keys` map lookup (security-audit.md:283-286). Recommendation: P3 cleanup, not critical.

---

## Health Scores (Re-Based for Non-Phoenix OTP)

This project has no database, no Ecto, no LiveView, no Phoenix. Standard Phoenix criteria (migrations, N+1 queries, LiveView authorization, sobelow) are inapplicable. Scores re-based over only applicable criteria.

| Category | Score | Grade | Justification |
|---|---|---|---|
| **Architecture** | 90/100 | A | 6-module OTP app with zero compile-time cycles, clean boundaries, sound supervision (confirmed mix xref and safe linking); minor config-read duplication (P3) does not affect runtime structure. |
| **Performance** | 20/100 | F | Two P1 performance bugs in the main socket/voice path (unbounded mailbox causing ~2 MB queues and 30 s stalls; head-of-line blocking preventing voice during upstream wedges); three P2 client-side efficiency issues; fixable but currently critical on poor networks. |
| **Security** | 5/100 | F | Three P1 vulnerabilities: /ws allows cross-site hijacking (no Origin check), unauthenticated unlimited sessions (drain quota indefinitely), and API keys leak to production logs via inspect(reason). Fixes are well-documented but not yet applied. |
| **Test Quality** | 80/100 | B | 49 tests, zero flakes, good async discipline and boundary mocking; two P1 coverage gaps in critical socket.handle_in binary path and init/1, and P2 gaps in terminate/2 cleanup and malformed handshakes. |
| **Dependencies** | 92/100 | A | All deps up-to-date and audit-clean; websock is a missing direct dep (transitive via bandit/websock_adapter) and websock_adapter pin is looser than the project's own stated policy; minor coupling to private gemini_ex message not test-guarded. |

---

## P3 Issues (Hygiene & Polish)

- String.to_atom/1: replace with `@arg_keys` map
- max_frame_size: 1_000_000 → 64_000
- Plug.Static at "/": add `only: ~w(index.html main.js pcm-processor.js)` allowlist
- Application.get_env(:port): use `LiveDJ.config().port` instead
- websock missing from mix.exs: add as direct dep (transitive via bandit/websock_adapter)
- websock_adapter pin: tighten to "~> 0.6" (already at 0.6.0)
- gemini_ex private-message canary test: add to detect arity change (deps-audit.md:39-49)
- Toolchain not pinned: add .tool-versions or adjust mix.exs floor (currently 1.20.3/OTP 29, declared ~> 1.17)
- .claude/ gitignore policy: decide explicitly (currently uncommitted)
- .dockerignore with no Dockerfile: add Dockerfile or delete .dockerignore
- Tool args type coercion: coerce to strings server-side; guard JSON.parse client-side
- Security headers: add CSP, X-Content-Type-Options, referrer-policy, HSTS (if TLS)

---

## Coverage Verification

| File | Represented | Key Items |
|---|---|---|
| arch-review.md | Yes | Module boundaries (✓), config duplication (P3), stale references (P3) |
| security-audit.md | Yes | CSWSH (P1), uncapped sessions (P1), frame validation (P2), API key logs (P1), static allowlist (P3), String.to_atom (P3), .claude/ gitignore (P3) |
| perf-audit.md | Yes | Mailbox backpressure (P1), HOL blocking (P1), barge-in spam (P2), allocation (P2), DOM reflow (P2), teardown (P2), max_frame_size (P3) |
| test-audit.md | Yes | socket.handle_in coverage (P1), init/1 coverage (P1), terminate/2 (P2), ordering assertion (P2), WebSocket handshake (P2) |
| deps-audit.md | Yes | Vulnerabilities/audit clean (✓), outdated status (✓), websock missing dep (P3), websock_adapter pin (P3), gemini_ex coupling test (P2), toolchain (P3) |

All 5 input files represented. No coverage gaps.

---

## Recommended Priority Order

1. **P1 Security** — Origin allowlist, concurrency cap, session ticket, API key redaction (enable safe deployment)
2. **P1 Performance** — Mailbox shedding + 2 s send_timeout + process flags, HOL hold-off + 250 ms timeout (survival on poor networks)
3. **P2 Security** — Frame validation + token bucket rate limit
4. **P2 Performance** — Worklet edge-trigger + zero-alloc process(), transcript coalescing, teardown
5. **P3 Cleanup** — String.to_atom replacement, max_frame_size, static allowlist, gemini_ex test canary, toolchain pin
