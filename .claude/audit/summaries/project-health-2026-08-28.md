# Project Health Audit — live_dj

**Date:** 2026-08-28
**Scope:** full audit, 5 parallel specialists
**Project shape:** plain Elixir OTP app (Bandit + Plug + WebSock + gemini_ex). No Phoenix, no Ecto, no database.
**Framing:** teaching/demo repo — an Elixir port of a Python cookbook episode, run locally with headphones. Severity below is split into "matters now on a laptop" vs "only matters if deployed."

## Overall: 74 / 100 — Grade C (Needs Attention)

⚠️ **Critical Issues Override triggered** — the methodology flags any audit with a security vulnerability as CRITICAL regardless of numeric score. Here that is the unauthenticated `/ws` endpoint. See the deployment caveat: it is a non-issue on localhost and a severe one the moment this is exposed.

| Category | Score | Grade | Weight | Driver |
|---|---|---|---|---|
| Architecture | 85 | B | 20% | Clean graph (0 cycles, 0 compile-time edges); loses points on the failed-`init/1` zombie state |
| Performance | 62 | D | 25% | 375 frames/sec mic cadence; blocking call that can drop every connection at once |
| Security | 65 | D | 25% | Unauthenticated `/ws`, error-detail leak to browser, no origin check or rate limit |
| Test Quality | 85 | B | 15% | 35 tests, real structs, failure paths covered; router untested, one timing assertion |
| Dependencies | 82 | B | 15% | All 5 at latest, none retired; `gemini_ex` under-constrained, no CVE scanner |

**Scoring note:** the standard methodology is Phoenix-shaped — 65 of the 100 Performance points (N+1, indexes, preloads, SELECT *) and the 30-point sobelow criterion are inapplicable to a project with no database and no Phoenix. Those criteria were re-based onto this project's actual surface (process/mailbox/streaming for Performance; manual OWASP review for Security) rather than scored as free points or as failures. Per Iron Law 3, this score is only meaningful as a baseline to track against future runs of this same project.

## Critical & High Findings

### Matters right now, on a laptop

1. **Rotate the API key** — `.env:3`. Git verdict is **clean**: `.env` is gitignored (`.gitignore:14`), is not in the index, and was never committed. But the file holds a live-format key in plaintext, and audit tooling has now read it. Rotate in AI Studio, then add a `.dockerignore` before any container build.

2. **Failed session leaves an immortal zombie socket** — `socket.ex:78-81`. On Live-session open failure `init/1` returns `{:push, error_frame(reason), %{session: nil}}`, so the socket stays open forever; every later binary frame hits the `session: nil` no-op clause. Two auditors independently established why the 60 s idle timeout never rescues it: the read timer resets on every frame arrival, and the browser worklet streams continuously. Fix: `{:stop, :normal, 1011, error_frame(reason), %{session: nil}}`.

3. **`send_realtime_input` timeout is NOT caught by `trap_exit`** — `socket.ex:91`, `minimal.ex:46`. It is a blocking `GenServer.call` with an un-overridable 5 s default. A call timeout raises an exit *inside the caller*, and `trap_exit` converts exit *signals*, not in-process raises — so the `{:error, reason}` clause at `socket.ex:95` is dead code for that path. One upstream stall drops every browser connection simultaneously. Fix: a project-owned wrapper with an explicit timeout and `catch :exit`.

4. **`error_frame/1` pushes `inspect(reason)` to the browser** — `socket.ex:193-195`. Leaks upstream close reasons, quota vs. billing vs. "key not valid" state — a free oracle. The upstream URL embeds `?key=`, so there is a latent credential path (not demonstrated; `gemini_ex` redacts in its own logs). Log the detail server-side, send the browser a fixed string. Same line as #2 — fix both in one edit.

5. **Mic emits 375 frames/sec** — `pcm-processor.js:31`, `main.js:99`. One WebSocket frame per 128-sample render quantum (~85 bytes), giving ~3.0x egress amplification and multiplying every downstream cost: 375 `GenServer.call`s, base64 encodes and TLS records per second per listener. Buffering to 100 ms in the worklet is a 37.5x reduction and directly relieves finding #3.

### Only matters if deployed beyond localhost

6. **`/ws` is unauthenticated with no connection cap, no origin check, no rate limit** — `router.ex:21-29`, `application.ex:12`. Every accepted socket opens a billed Gemini session on the owner's key, and Bandit binds all interfaces. Combined with finding #5, each attacker connection costs ~11,250 process hops/sec as well as quota. Also CSWSH-able: any page can drive a developer's localhost key. Gate the upgrade with a short-TTL signed ticket, cap connections, check `Origin`.

7. **`gemini_ex` is under-constrained** — `mix.exs`. `~> 0.17` means `>= 0.17.0, < 1.0.0`, not `< 0.18.0`. That library shipped 7 minors in 5.5 months and **replaced its entire Live WebSocket transport in a minor (0.16.0)**. Since `socket.ex` pattern-matches `Gemini.Types.Live.*` in function heads, a shape change is a runtime `FunctionClauseError`, not a compile error. Tighten to `~> 0.17.0`.

## Action Plan

**Immediate**
1. Rotate the Google API key; add `.dockerignore`.
2. `socket.ex:78-81` + `:193-195` — one edit: stop the socket on init failure, and stop echoing `inspect(reason)` to the browser.
3. `mix.exs` — pin `{:gemini_ex, "~> 0.17.0"}`.

**Short-term**
4. Wrap `send_realtime_input` with an explicit timeout and `catch :exit`.
5. Buffer the worklet to ~100 ms (37.5x fewer frames).
6. Add `{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}` — `mix hex.audit` only reads retirement flags, not advisory databases.
7. Add `Plug.Test` coverage for `router.ex` (the `SOCKET_HANDLER` swap, `/healthz`, the 404 catch-all) — the one genuine test gap.

**Long-term / only before any deployment**
8. Auth ticket + connection cap + `Origin` check on `/ws`.
9. Widen the `tools_test.exs` timing assertion to ~50 ms as a smoke check, preserving the instant-return guardrail's intent.
10. Scope `Plug.Static` with `only:` — `/assets/mira_persona.txt` currently serves the system prompt publicly.
11. Prune `test/support` from `elixirc_paths(:test)` in `mix.exs` (the directory does not exist).

## Deliberate non-findings

`LiveDJ.Minimal` and `LiveDJ.Gotcha` are pedagogical duplicates and are **not** dead code. Verified clean and explicitly cleared: `String.to_atom` in `tools.ex:77` is not attacker-controlled (both callers pass literals — no atom exhaustion); `main.js` uses `textContent` at every sink (no model-driven XSS); `config/test.exs`'s `"test-key"` cannot reach a non-test build; `activeSources` is correctly cleaned by `onended`.

## Reports

- `.claude/audit/reports/{arch-review,perf-audit,security-audit,test-audit,deps-audit}.md`
- `.claude/audit/summaries/consolidated.md`
