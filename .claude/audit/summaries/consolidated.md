# Consolidated Audit Summary

**Strategy**: Compress  
**Input**: 5 reports, ~9,600 tokens  
**Output**: ~3,800 tokens (60% reduction)  
**Scope**: Plain Elixir/Plug/Bandit demo (localhost, teaching artifact, not production service)

---

## CRITICAL & HIGH FINDINGS

### 1. **Unauthenticated `/ws` + unlimited connections — direct quota theft**
**Files:** `router.ex:21-29`, `application.ex:12`  
**Severity:** CRITICAL (only matters if app is ever exposed beyond localhost)  
**Sources:** Security 2.1; Performance H1, H2

Every accepted WebSocket immediately starts a billed Gemini Live session with no auth token, session secret, or per-IP cap. Bandit binds all interfaces (no `ip:` option). At 10 concurrent attackers, ~11,250 process hops/sec × 10 + full Gemini quota drain.

**Fix:** Require a short-TTL signed ticket (`Plug.Crypto.sign/3` minted by authenticated route, single-use, peer-IP bound) before upgrade. Minimum gate in router:
```elixir
:ok <- LiveDJ.Auth.verify_ticket(conn.params["ticket"])
:ok <- LiveDJ.Limiter.allow(peer_ip(conn))
```
Then `max_connections: 50` on Bandit, `timeout: 15_000`, `max_frame_size: 65_536`.

---

### 2. **`init/1` failure leaves zombie WebSocket alive indefinitely**
**File:** `socket.ex:78-81`  
**Severity:** HIGH  
**Sources:** Architecture 1; Performance L1

On Live session open failure, code returns `{:push, error_frame(reason), %{session: nil}}` instead of `{:stop, :normal, 1011, error_frame(reason), %{session: nil}}`. Socket stays open, all binary frames match the `session: nil` guard and silently no-op. Browser's AudioWorklet streams mic continuously at 375 Hz; those frames **keep resetting the `timeout: 60_000` idle timer** (read timer resets on every frame arrival). The connection never times out and never self-closes.

**Cross-check:** Performance audit separately concluded `timeout: 60_000` is "safer than it looks (read timer resets on every continuation)" — this is exactly the problem. Both audits agree: timer resets per-frame, so a zombie with continuous mic traffic is immortal.

**Fix:** Return combined stop+push tuple:
```elixir
{:stop, :normal, 1011, error_frame(reason), %{session: nil}}
```

---

### 3. **`send_realtime_input` timeout is not caught by `trap_exit` — crashes connections**
**File:** `socket.ex:91`, `minimal.ex:46`  
**Severity:** HIGH  
**Sources:** Performance H2; Architecture 5

`GenServer.call(session, {:send_realtime_input, ...}, 5_000)` blocks the socket process. On timeout, an **exit is raised inside the caller** (socket), not a signal sent to a linked process — `trap_exit` only converts exit *signals*, not in-process raises. A 5s upstream stall crashes the browser connection immediately. At 10x listeners, a single Gemini-side stall or TLS backpressure drops every connection simultaneously, with no reconnect.

**Cross-check:** Architecture separately identified the session is unsupervised, relying on `trap_exit + exact-pid matching` for correctness. This reveals the fragility: the protective `trap_exit` at `socket.ex:44` was never designed to catch `GenServer.call` timeouts originating in its own process. 

**Fix:** Wrap in a project-owned module with explicit timeout and catch:
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

---

### 4. **`error_frame/1` leaks internal error details to unauthenticated browser**
**File:** `socket.ex:193-195`  
**Severity:** HIGH  
**Sources:** Security 1.4

`inspect(reason)` on upstream Gemini/WebSockex errors is pushed to the browser as `{"type":"error","message": ...}`. Attacker oracle on quota exhaustion ("key expired" vs "quota spent"), API version, model details, and latent path for full URL with API key if exception/stacktrace is in `reason`.

**Overlaps:** Same line's state handling (`%{session: nil}` from finding #2) is where this leaks. **Fix both in one change:**
```elixir
defp error_frame(_reason) do
  Logger.error("live session error: #{inspect(reason)}")
  json(%{type: "error", message: "the line dropped — try again"})
end
```

---

### 5. **Mic chunking at 375 frames/sec — scheduler thrashing multiplier**
**File:** `priv/frontend/pcm-processor.js:9-33`, `main.js:98-101`  
**Severity:** HIGH  
**Sources:** Performance H1

Browser posts PCM message on every AudioWorklet quantum (128 samples = 375/sec at 48 kHz). Forwarded straight to `ws.send()`. Downstream: 375 `handle_in/2`, 375 `GenServer.call`, 375 `Jason.encode!`, 375 `Base.encode64`, ~11,250 inter-process hops/sec at 10x. Scheduler work dominated by overhead, not audio.

**Fix:** Buffer in worklet to ~100 ms (1,600 samples @ 16 kHz) before posting. Reduces frames to **10/sec** (37.5x reduction), direct improvement to H2 and H3 above since GenServer calls drop 37.5x as well.

---

### 6. **`.env` key is live and readable by tooling — needs rotation NOW**
**File:** `.env:3`  
**Severity:** HIGH (operational, not git leak)  
**Status:** Clean git verdict (.env is gitignored, never committed)

The `.env` file itself is correctly gitignored and not in history. However, it contains a plaintext live Google AI Studio key readable by any process, editor plugin, agent tool, or future `git add -f`/`tar`/Docker `COPY`. The key has been read by this audit.

**Fix (right-now item, not deployment-dependent):**
1. Rotate the key in AI Studio immediately
2. Store new key only in shell environment or secret manager
3. Add `.dockerignore` containing `.env` before any container build

---

## Cross-Category Correlations

| Finding | Architecture | Performance | Security | Combined Insight |
|---------|---|---|---|---|
| **Zombie socket timeout** | socket stays open with `session: nil`, frames reset timer | "timer resets on every continuation" | — | Both say same thing: frame arrival resets timer → zombie never closes |
| **Blocking call failure** | Session unsupervised, `trap_exit` expected to catch exits | `trap_exit` doesn't catch in-caller timeout; kills connections | — | Architecture's protective assumption (trap_exit) violated by perf issue; session left orphaned |
| **error_frame leakage** | State handling at this line | — | `inspect(reason)` echoes internals + latent cred path | Same code location, two impacts; fix once |
| **Auth + cost** | — | 11,250 hops/sec per listener at 10x | No auth, unlimited connections | Attacker can open N listeners for free quota drain at massive scheduler cost |

---

## Medium/Low Findings — Compact Table

| File:Line | Issue | Severity | Auditor |
|---|---|---|---|
| `lib/live_dj.ex:25-31` | `config/0` hard global-env read, no injection point, testability hazard | MEDIUM | Arch |
| `socket.ex:150-156` | Unreachable `terminate/2` clause | LOW | Arch |
| `application.ex:15-19` | Misleading log order (claims listening before `Supervisor.start_link`) | LOW | Arch |
| `socket.ex:158-177` | `handle_tool_call/2` mixes transport + domain logic | LOW | Arch |
| `socket.ex:60-62` | Unbounded downstream mailbox; ~13 KB per message | MEDIUM | Perf |
| `priv/frontend/main.js:21-26` | Unbounded transcript DOM; forced reflow per fragment | MEDIUM | Perf |
| `main.js:79,107` | Dropped connection unrecoverable; mic never released | MEDIUM | Perf |
| `main.js:62-63` | `nextStart` drift + barge-in audio race | MEDIUM | Perf |
| `router.ex:27` | No `Origin` header validation — CSWSH | HIGH (localhost only) | Sec |
| `router.ex:27` | `max_frame_size: 1_000_000` is 12,000x actual need | LOW | Perf |
| `deps/gemini_ex/...` | Telemetry overhead (750/sec listener) on no handlers | LOW | Perf |
| `socket.ex:73-74` | Stale audio backlog on slow `Session.connect` | LOW | Perf |
| `config/runtime.exs:6-20` | Hand-rolled dotenv parser: env injection + arbitrary keys | MEDIUM | Sec |
| `deps/gemini_ex/...` | API key in crash reports/SASL logs | MEDIUM | Sec |
| `router.ex:13,16` | `Plug.Static` at `/` with no `only:` — persona text exposed | MEDIUM | Sec |
| `socket.ex:87-98` | Unvalidated client binary forwarded upstream; no length/alignment check | MEDIUM | Sec |
| `socket.ex:182` | `Base.decode64!` can crash socket on malformed base64 | LOW | Sec |
| `socket.ex:190-191` | `transcript_role/1` crashes on unknown role | LOW | Sec |
| `socket.ex:168` | `Enum.map` destructure crashes session if `id` missing | LOW | Sec |
| `router.ex` | No security headers (CSP, X-Frame-Options, etc.) | LOW | Sec |
| `config/runtime.exs:47` | Non-numeric `PORT` raises `ArgumentError` | LOW | Sec |
| `lib/live_dj/router_test.exs` | MISSING — no tests for router logic | WARNING | Test |
| `test/live_dj/tools_test.exs:37-56` | Timing assertion flakes on loaded CI (1ms threshold) | WARNING | Test |
| `mix.exs:22` | Misleading `elixirc_paths(:test)` points to nonexistent `test/support/` | SUGGESTION | Test |
| `mix.exs:34` | `{:gemini_ex, "~> 0.17"}` under-constrained (allows 0.18+); minors carry breaking changes | HIGH | Deps |
| `mix.exs` | No `mix_audit` for CVE scanning | MEDIUM | Deps |
| `mix.exs:31` | `{:websock_adapter, "~> 0.5"}` already drifted to 0.6 in lock | LOW | Deps |
| `.formatter.exs` | Does not import plug's DSL formatter config | LOW | Deps |

---

## Ranked "Fix These First" (Severity × Ease)

1. **`socket.ex:193-195` — Stop leaking errors to browser** | 15 min | Security 1.4 + Architecture overlap  
   Replace `inspect(reason)` with fixed string, log detail server-side.

2. **`socket.ex:78-81` — Return stop tuple, not push** | 5 min | Architecture 1  
   One-line fix: `{:stop, :normal, 1011, error_frame(reason), %{session: nil}}`

3. **`router.ex:21-29` — Add ticket + connection cap** | 45 min | Security 2.1 (critical if deployed)  
   Requires auth.verify_ticket/1 helper; add Bandit `max_connections: 50`.

4. **`socket.ex:91` + `minimal.ex:46` — Wrap blocking call** | 30 min | Performance H2  
   Create `LiveDJ.LiveSession` module with catch, pass explicit timeout.

5. **`.env` key rotation** | depends on Google AI Studio | Security 1.1 (NOW)  
   Rotate key, update `.env` locally, add `.dockerignore`.

6. **`priv/frontend/pcm-processor.js` — Buffer to 100 ms** | 30 min | Performance H1  
   Accumulate samples, post when `>= 1600`; reduces downstream load 37.5x.

---

## Deduplication Notes

- **error_frame issue (Security 1.4 + Architecture 5):** flagged for state AND leakage; single code location, fix once.
- **Timer/zombie (Architecture 1 + Performance L1):** both auditors independently reached same conclusion via different paths; combined insight in cross-category section.
- **Blocking call timeout (Performance H2 + Architecture 5):** different aspects of same failure mode; combined insight in cross-category section.

---

## Coverage

| File | Represented | Key Items |
|---|---|---|
| arch-review.md | ✓ | 3 CRITICAL/HIGH, 2 MEDIUM cross-checks |
| perf-audit.md | ✓ | 3 CRITICAL/HIGH, 4 MEDIUM compressed to table |
| security-audit.md | ✓ | 3 CRITICAL/HIGH, 4 MEDIUM compressed to table |
| test-audit.md | ✓ | 1 WARNING (router gap), 1 suggestion in table |
| deps-audit.md | ✓ | 1 HIGH, 1 MEDIUM, 3 LOW in table |

**Coverage gap:** None. All 5 input files represented.

---

## Context Reminder

This is a **demo/teaching repo** (Elixir port of a Python cookbook episode), run locally with headphones on a developer's machine, not a deployed service. All "critical" security findings above carry that framing:

- **Only matters if deployed:** Auth gate (2.1), origin check (2.2), resource caps (2.3), persona exposure (2.4), security headers (2.5)
- **Matters right now on localhost:** `.env` key rotation (1.1), `error_frame` leakage (1.4), zombie socket (Architecture 1), blocking call crashes (Performance H2)

Deployment of this app (e.g. exposed to the internet) would immediately elevate all "only if deployed" findings to critical. Do not deploy without fixing the above list in rank order.
