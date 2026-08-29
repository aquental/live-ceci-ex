# Consolidated Audit Summary — live-ceci

**Date**: 2026-08-29
**Strategy**: Compress (critical findings + cross-category correlations, deduplication)
**Input**: 5 reports (~22k tokens)
**Output**: Critical-only findings with POC/production guidance

---

## Executive Summary

The codebase is structurally sound (clean module boundaries, no compile-time cycles, correct OTP patterns). The real risks are **cost/confidentiality** (unauthenticated, unmetered pipe to metered APIs) and **structural** (one process serializes both upstream and downstream, causing blocking and unbounded queue growth). Two cross-cutting patterns recur across security, performance, and testing audits. Three findings require action before this POC touches the internet; one is already fixed.

**POC Verdict**: Currently safe for localhost-only testing. Network deployment blocked on three findings; two are 10-line fixes.

---

## Critical Findings (P1)

### 1. Socket Process Serializes Upstream Send and Downstream Push — Dual-Path Stall + Unbounded Mailbox

**Found by**: perf (P1 #1, #2), security (P2-4) [**CROSS-CATEGORY CORRELATION**)

- **The pattern**: `lib/live_ceci/socket.ex:76-89` calls `provider.send_audio/2` synchronously in the WebSocket connection process that also owns `handle_info/{:push, ...}`. Both Gemini (`GenServer.call(..., 1_000)`) and Grok (`WebSockex.send_frame(..., 1_000)`) are blocking, once per ~100 ms frame.
  - **Performance consequence**: Slow upstream ACK stalls voice *in both directions* — frames waiting to push to browser are blocked behind the upstream send. Up to 1 s jitter per frame, up to 10 times/sec exposure. This is 80% of the entire measured p50 latency budget (1220/1806 ms).
  - **Security consequence**: When browser stalls (backgrounded tab, throttled network), socket blocks in `send`, but provider keeps `send/2`-ing decoded 24 kHz voice into the mailbox with no cap and no drop policy. Repeat across connections (nothing caps them) until OOM.

- **Fix (3-minute change)**:
  ```elixir
  # lib/live_ceci/application.ex — remove internet exposure (POC)
  {Bandit, plug: LiveCeci.Router, port: port, ip: {127, 0, 0, 1}}
  
  # lib/live_ceci/socket.ex — shed downstream on stall (production)
  def handle_info({:provider, {:voice, pcm}}, state) do
    {:message_queue_len, n} = Process.info(self(), :message_queue_len)
    if n > @max_queued_frames do
      {:stop, :normal, 1011, json(%{type: "error", message: "a linha caiu"}), state}
    else
      {:push, [{:binary, pcm}], state}
    end
  end
  ```

- **POC-acceptable?** Yes (bind to 127.0.0.1 removes internet exposure; unbounded mailbox only occurs if someone on localhost stalls the browser).
- **Cheap to fix?** Yes (~10 lines, zero business logic).
- **When to fix**: Before any network-facing deployment.

### 2. Unmetered Pipe to Metered API; Per-Connection Cost Amplification

**Found by**: security (P1-1)

- **Issue**: `/ws` has no rate limit, no per-connection byte budget, no session-duration cap, no frame format check. `max_frame_size: 1_000_000` caps *one frame*, not the stream. Bandit binds `0.0.0.0` (internet-exposed).
- **Attack**: `while true; do ws.send(random(1_000_000)); done` from anywhere that routes to port 8000 drains the API key's quota in seconds. Each of N attackers opens N independent billed sessions.
- **Fix (same as #1 above)**: Bind to `127.0.0.1`. When reachable, add per-connection byte budget in `handle_in/2`:
  ```elixir
  def handle_in({pcm, [opcode: :binary]}, %{sent: sent} = state)
      when session != nil do
    cond do
      sent + byte_size(pcm) > @max_session_bytes -> {:stop, :normal, ...}
      rem(byte_size(pcm), 2) != 0 -> {:ok, state}  # not s16le; drop
      true -> ...
    end
  end
  ```
- **OWASP**: API4:2023 Unrestricted Resource Consumption.
- **POC-acceptable?** Yes if localhost-only. Network deployment requires both.

### 3. Model-Controlled Tool Argument of Non-String JSON Type Crashes Session (+ Silent Corruption)

**Found by**: security (P1-2), reproduced and extended by orchestrator

- **Crash path**: `lib/live_ceci/tools.ex:151-166` — `arg/2` applies no type check. `join/1` calls `Enum.join/2` → `String.Chars.to_string/1`, which is **not implemented for maps**. Raises `Protocol.UndefinedError`. Example: model emits `agendar_sessao({"paciente": {"iniciais": "A.B."}, ...})` — session dies mid-call.

- **Silent corruption variants** (more dangerous):
  - **LIST argument silently mangles**: `paciente ["A","B"]` → `detail "AB"` — array coerced to string without delimiter, structure lost.
  - **INTEGER argument passes through unchecked**: `mes 8` → `detail 8` (int) in a field `@type`-declared as `String.t()`. Ceci confirms out loud an operation with corrupted data.

- **Fix**: Coerce and bound at the boundary:
  ```elixir
  defp arg(args, key) when is_map(args) and is_atom(key) do
    case fetch_either(args, key) do
      v when is_binary(v) -> String.slice(v, 0, 200)
      v when is_number(v) -> to_string(v)
      _ -> ""
    end
  end
  ```

- **POC-acceptable?** **No.** These are remote, unauthenticated, repeatable session kills (crash) + data corruption (silent). Fix now even for POC.
- **Cheap to fix?** Yes (~15 lines).

### 4. Orphaned Billed Upstream Session When `open/1` Fails After Connect

**Found by**: security (P2-5), confirmed by orchestrator

- **Issue**: `lib/live_ceci/provider/grok.ex:50-60` — `open/1` does `WebSockex.start_link/4` then `send_json(ws, session_update(...))`. If that send times out, the `with` returns the error and the already-connected WebSockex pid is **dropped on the floor**. `socket.ex:69` returns `{:stop, :normal, 1011, ..., %{session: nil}}`. `terminate/2` skips `provider.close/1` because `session` is `nil`. WebSockex does not trap exits; `:normal` exit to a non-trapping process is discarded. **The upstream socket to `api.x.ai` stays open and billed until xAI's idle timeout.**

- **Scenario**: Slow xAI handshake under load. Each affected browser refresh strands one paid upstream connection.

- **Fix**:
  ```elixir
  {:ok, ws} ->
    case send_json(ws, session_update(opts)) do
      :ok -> {:ok, ws}
      {:error, reason} -> close(ws); {:error, reason}
    end
  ```

- **POC-acceptable?** Only if xAI usage is metered/low in testing. Otherwise a bug to find quickly under load.
- **Cheap to fix?** Yes (4 lines).

### 5. `.env` Leak Into Test Environment — **RESOLVED**

**Found by**: test-audit (P1), confirmed as fixed by orchestrator

- **What was found**: `config/runtime.exs` loaded `.env` unconditionally for all `config_env()`, including `:test`. Developers' local `.env` could silently override `MODEL`, `VOICE`, `LANGUAGE`, `SILENCE_DURATION_MS`, `FRAME_SAMPLES` — not just `PORT`. Real second face: `GOOGLE_API_KEY` being loaded into test env's app config, overriding `config/test.exs`.

- **Fixes now in place**:
  - `config_env() != :test` guard on dotenv load (line ~6)
  - API-key block gated by `config_env() != :test`
  - PORT gated
  - New test block in `test/live_ceci_test.exs` pinning exact literals (e.g. `port == 4002`, not `is_integer`)
  - Suite: 128 green, deterministic across 3 runs

- **Status**: Closed as resolved. Cross-reference: config overrides could have silently skewed performance measurements (FRAME_SAMPLES/SILENCE_DURATION_MS).

---

## Medium-Severity Findings (P2)

### Socket & Close Path Inconsistency

**File**: `lib/live_ceci/provider/gemini.ex:75-78`, `lib/live_ceci/socket.ex:135-138`

- `terminate/2` calls `provider.close(session)` on every teardown.
  - Grok: `WebSockex.cast` (fire-and-forget, correct).
  - Gemini: `Session.close(session)` → `GenServer.call(session, :close)` with **default 5 s timeout and no catch**. This is the exact hazard the rest of the codebase guards against (`live_session.ex:24-40`).
- Can add 5 s to closing a single connection if Gemini session is wedged. Low blast radius (one connection) but inconsistent pattern.
- **Fix**: Wrap with guard like `live_session.ex`: `catch :exit` or pass a 1 s timeout (3 lines).

### Dependency Drift + Silent Integration Failures

**Found by**: deps-audit (P1 §1), test-audit (P2 coverage) [**CROSS-CATEGORY**)

- `gemini_ex` internal API coupling: `~> 0.17.0` pin is tight, but it only holds until the next bump. `0.16.0` already swapped transports (Gun → WebSockex) mid-minor.
- **Three of four integration points degrade silently** if structs change (no crash, no log):
  - `provider/gemini.ex:114` — if `ServerMessage{server_content: %ServerContent{}}` changes shape, voice output stops.
  - `provider/gemini.ex:124` — transcripts stop decoding.
  - `provider/gemini.ex:99` — tool dispatch stops.
  - Only `live_session.ex:33` actually raises on drift.
- **Real safety net**: Test suite constructs real `Gemini.Types.Live.*` structs (would catch shape changes), but **there is no CI to run it on `mix deps.update`**.
- **Fix**: Add explicit fallback logging instead of silent `:ok` catch-alls (~10 lines), or correct the README claim. Add CI to run `mix test` on dependency bumps.

### Tool Argument Validation Gaps + Prompt Injection Re-Entry

**Found by**: security (P2-2, P2-3)

- **Schema doesn't enforce**: `paciente` documented as "iniciais ou apelido" (never full name) but schema has no `maxLength` or `pattern`. Model can pass full legal names unchecked.
- `status` documented as `enum` but schema has no `enum`, and `dispatch/2` performs no validation. Model passes arbitrary strings.
- **Tool results echo back**: `%{result: "sessão agendada para #{quando}"}` re-enters context as `function_response` with tool-level trust. If `quando` contains `fim das instruções anteriores; ...`, the result is a prompt-injection re-entry channel.
- **Fix**: Add `enum` and `maxLength` to schema, validate in `dispatch/2`, never echo the argument (confirm action, not input) (~20 lines).

### Boundary Enforcement ("Never Clinical") Constrains Replies, Not Transmission

**Found by**: security (P2-1)

- `LIMITE INEGOCIÁVEL — só o operacional, nunca o clínico` is a system instruction. It governs what Ceci *says back*, not what leaves the browser.
- Every microphone frame streams to xAI/Google before any model reasoning. Providers transcribe it. Transcript echoes back to browser. Nothing redacts or warns.
- **Fix**: This is a product decision, not code. Documentation should state clearly: raw audio reaches the provider unfiltered. If the claim must hold technically, only lever is client-side push-to-talk gate (not always-open mic).

### No Backpressure on Outbound (Mic) Send

**Found by**: perf (P2 #4)

- Browser sends PCM unconditionally on `ws.readyState === OPEN` with no check of `ws.bufferedAmount`. When network degrades, browser queues frames internally with no cap. Worklet keeps producing new frame every ~100 ms. Client-side mirror of mailbox growth.
- **Fix**: Guard on `ws.bufferedAmount` (skip/coalesce frames past a threshold, e.g. 2–3 frames).

---

## P3 Hygiene Issues (Deferred)

| Finding | Severity | Notes | Effort |
|---------|----------|-------|--------|
| No security response headers | P3 | Missing CSP, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`. Platform already blocks mic clickjacking via autoplay policy; CSP is defence-in-depth. | 4 lines |
| Dead route (`GET /`) | P3 | `Plug.Static` at `/` with `index: ["index.html"]` runs before `plug :match`, shadowing the manual route at `router.ex:46-48`. Verified dead (not exploitable). Delete it. | 1 line |
| Per-render array allocation on audio thread | P2 | `priv/frontend/pcm-processor.js:34-72` allocates fresh `Array` per 128-sample quantum (~375/sec). Not currently causing dropouts but avoidable: fixed-size `Float32Array`, write by index. | ~20 lines JS |
| Process.sleep timing assumption | P2 | `grok_test.exs:193–197, 293–297` use `Process.sleep(20)` to wait for process death. Flaky under scheduler pressure. Replace with `Process.monitor` + `assert_receive {:DOWN, ...}` (correct pattern exists in same file at line 285–291). | ~5 lines |
| Wall-clock assertion flaky under load | P2 | `tools_test.exs:98–111` — `@budget_us 50_000` catches stalls but reads as unrelated stalls on the machine. Reductions now cover "real work" half; consider removing or widening (200 ms). | ~1 line |
| websockex constraint loose | P2 | `mix.exs:30` declares `{:websockex, "~> 0.4"}` (>= 0.4.0, < 1.0.0). `mix.lock` resolves to 0.5.1 (forced by gemini_ex). For 0.x packages, convention is three-segment. Tighten to `~> 0.5.1`. Same for `websock_adapter` (`~> 0.5` → `~> 0.6.0`). | 1 line |
| `websock` phantom direct dependency | P2 | `lib/live_ceci/socket.ex:32` declares `@behaviour WebSock`, but `websock` not in `mix.exs`. Arrives transitively. Add `{:websock, "~> 0.5"}` to protect the contract. | 1 line |
| websockex maintainer transfer + doubled blast radius | P2 | Ownership transferred from Azolo to witchtails org (2025-11-13). Now load-bearing for *both* Grok (hand-rolled) AND Gemini (0.16.0 swapped to WebSockex). Regression takes down both backends. | Awareness only |
| No toolchain pin and no CI | P2 | No `.tool-versions`, no `.mise.toml`, no CI. Elixir `~> 1.17` unbounded; machine runs 1.20.4/OTP 29. Absence of CI means dependency drift is never caught. Add `.tool-versions` + minimal CI with `mix test` on push. | ~10 lines YAML |
| No TLS termination in-process | P3 | Bandit plaintext. Safe behind a proxy; unsafe without. Document proxy requirement or add cert-based TLS. | Documentation |
| Unguarded socket test assertions | P2 | `test/live_ceci_test.exs:9–10, 38–45` — tests assert `is_binary(model) and model != ""`, not the exact literal. Would catch override only by accident. Already mitigated by resolved `.env` leak, but good discipline for future. | ~3 lines |

---

## Cross-Category Correlations

| Pattern | Security | Performance | Testing | Action |
|---------|----------|-------------|---------|--------|
| **Socket dual-path stall + unbounded mailbox** | Attacker stalls browser; mailbox grows OOM. | Slow upstream ACK stalls downstream voice (80% of latency budget). | No explicit test for mailbox shedding. | **P1 #1**: queue monitoring + shed on stall. Bind to 127.0.0.1 for POC. |
| **Dependency drift + silent degrade** | Not directly security, but silent wire drift. | Silent loss of transcript/voice/tool dispatch. | Tests construct real structs (would catch drift), but no CI runs them on `mix deps.update`. | Add fallback logging to silent catch-alls. Add CI. |
| **Tool argument validation holes** | Crash + silent corruption + prompt injection re-entry. | Corrupted data (int in string field, list → concat) goes into tool response, re-enters conversation. | Tests don't cover non-string argument types. | **P1 #3**: coerce + bound at boundary. Add test for map/list/int. |
| **Config override risk** | If `.env` overrides `GOOGLE_API_KEY` during test, real key could leak. | FRAME_SAMPLES/SILENCE_DURATION_MS overrides silently skew measurements. | `.env` leak fixed; assertions now pinned to literals. | Monitor config overrides in future. |

---

## POC-Acceptable vs. Fix-Now Grid

| Finding | POC-OK? | Effort | Fix Now? | Defer To? |
|---------|---------|--------|----------|-----------|
| Bind to 127.0.0.1 (P1 #1 + #2) | Yes | 1 line | No (POC) | Pre-network deployment |
| Unbounded mailbox shedding (P1 #1) | Somewhat | 5 lines | No (POC) | Pre-network deployment |
| **Tool argument crash + corruption (P1 #3)** | **No** | 15 lines | **Yes** | — |
| **Orphaned billed session (P1 #4)** | Conditional | 4 lines | **Yes** | — |
| Gemini close path timeout (P2 close) | Yes | 3 lines | No | Pre-production |
| Dependency drift silent degrade (P2 deps) | Yes | ~10 lines logging | No | Pre-1.0/production hardening |
| Tool validation gaps (P2 validation) | No | 20 lines | Maybe (easy win) | — |
| CSP headers (P3-1) | Yes | 4 lines | No | — |
| Per-render allocation (P2 audio) | Yes | ~20 lines | No | Post-POC optimization |
| websockex constraint tightening (P2) | Yes | 1 line | No (POC) | Next dependency bump review |
| No CI (P2 toolchain) | Yes | ~10 lines | No (POC) | Pre-production |

---

## Immediate Action Items

**Before POC Touches the Network:**
1. Fix **P1 #3** (tool argument crash/corruption): ~15 lines, fixes crash + silent data loss.
2. Fix **P1 #4** (orphaned session): ~4 lines, stops billing drain if handshake slow.
3. Fix **P1 #1/2** (bind to 127.0.0.1): ~1 line, removes internet-facing cost exposure.

**Before Pre-Production Deployment:**
- Socket mailbox shedding (5 lines) + per-connection byte budget (10 lines)
- Gemini close-path timeout (3 lines)
- Tool result sanitization (never echo arguments)
- Backpressure guard on client send (`ws.bufferedAmount`)
- Security headers (CSP, nosniff, etc.)
- CI + `.tool-versions` to catch dependency drift
- Fallback logging for gemini_ex silent degrade paths

---

## Coverage Verification

| File | Represented | Key Items |
|---|---|---|
| arch-review.md | Yes | Clean module boundaries; gemini_ex coupling (P2); websockex constraint (P3, corrected per orchestrator) |
| perf-audit.md | Yes | Socket dual-path stall (P1 #1); unbounded mailbox (P1 #2); per-render allocation (P2); client backpressure (P2) |
| security-audit.md | Yes | Unmetered API (P1 #1, #2); tool argument crash (P1 #3); orphaned session (P1 #4); validation gaps (P2); prompt injection (P2); boundary enforcement (P2) |
| test-audit.md | Yes | `.env` leak RESOLVED; loose assertions; timing assumptions (P2) |
| deps-audit.md | Yes | gemini_ex silent degrade (P2); websockex loose constraint (P2); websock phantom dep (P2); no CI (P2); websockex maintainer transfer (P2) |

All 5 input files represented. No coverage gaps.

---

## Health Scores

This project: plain Elixir OTP voice-agent, ~850 LOC in lib/, no Phoenix/Ecto/database. Scores re-based over only applicable criteria.

| Category | Score | Grade | Notes |
|---|---|---|---|
| **Architecture** | 90/100 | A | 10 modules, zero compile-time cycles, clean boundaries, sound supervision; minor xref cosmetic cycle acknowledged. |
| **Security** | 40/100 | D | P1 #1, #2: unmetered internet-facing pipe (1 line to fix); P1 #3: model-controlled crash/corruption (15 lines); P1 #4: orphaned session (4 lines). Three easily fixed findings block network deployment. **Known good**: no injection/XSS/path traversal, no committed keys. |
| **Performance** | 70/100 | C+ | P1 #1, #2: socket serialization + unbounded mailbox causes 30 s stalls on poor networks; fixable (5–10 lines). P2 findings on client optimization deferred. Baseline p50 latency good (1220/1806 ms) but structure under stress is vulnerable. |
| **Test Quality** | 75/100 | C+ | 128 tests, green and deterministic. P2 gaps: process timing assumptions (Process.sleep flakiness), unguarded wall-clock budget. `.env` leak fixed. Coverage of critical paths (socket init/close) incomplete. |
| **Dependencies** | 85/100 | B | All up-to-date and audit-clean. P2: gemini_ex coupling to private messages; websockex/websock_adapter loose constraints; websock phantom; no CI. P3: toolchain not pinned. |

---

## POC Readiness

**Localhost-only POC**: ✓ Ready after P1 #3 fix (15 lines). P1 #1 (bind 127.0.0.1) makes mailbox growth require active stall.

**Network deployment**: ✗ Blocked until P1 #1, #2, #3, #4 fixed (~35 lines total).

**Production hardening**: Pre-production checklist above (post-POC phase).
