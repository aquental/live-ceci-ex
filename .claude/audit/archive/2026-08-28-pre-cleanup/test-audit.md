# Test Health Audit — live-dj-ex

Scope confirmed: plain Elixir/Plug/Bandit app, no Phoenix/Ecto/DB/Mox. Baseline: `mix test` = 35 tests, 0 failures, 0.06s.

## 1. Coverage Gaps

- **LiveDJ.Minimal** (lib/live_dj/minimal.ex) — zero tests. `handle_info/2` pattern-matches on `%ServerMessage{server_content: %ServerContent{model_turn: %{parts: parts}}}` and builds `{:push, [...], state}` almost identically to `Socket.handle_info/2`'s `voice_frames/1`. It is explicitly a teaching artifact ("compare it with LiveDJ.Socket ... the difference is the entire app") and is not wired into `LiveDJ.Application` (only reachable via `SOCKET_HANDLER=minimal`). **Acceptable to leave untested** — it is dead code under normal boot and its one non-trivial line (voice frame extraction) is already covered by the equivalent logic in `socket_test.exs`. Low priority.

- **LiveDJ.Gotcha** (lib/live_dj/gotcha.ex) — zero tests. Both functions are one-line delegations to `Gemini.Live.Session.send_client_content/2` and `send_realtime_input/2`; the module's entire purpose is illustrative (`send_mic_audio_wrong/2` is *meant* to be the broken example). Testing it would require a live/mocked `Session` process, which is out of scope for this project's boundary (never mock the session GenServer directly per Iron Law 3, and there's no behaviour to mock against). **Acceptable to leave untested.**

- **LiveDJ.Application** (lib/live_dj/application.ex) — zero tests. `start/2` boots a real Bandit listener via `Supervisor.start_link/3`. Testing this typically means starting a real socket on a real port, which is integration-test territory this project doesn't otherwise do. **Acceptable to leave untested** for a project this size, but flag: if `port` is misconfigured (e.g. non-integer from env) there's no test catching it before runtime.

- **LiveDJ.Router** (lib/live_dj/router.ex) — zero tests. **This is the one real gap.** Unlike the above, `Router` is a `Plug.Router` and is directly testable with `Plug.Test.conn/3` + `LiveDJ.Router.call/2` with **no running server needed** — this is exactly what `Plug.Test` exists for. It has three pieces of real logic with zero coverage:
  - The `SOCKET_HANDLER` env-var swap (`get "/ws"` reads `Application.get_env(:live_dj, :socket_handler, LiveDJ.Socket)`) — untested, and a typo'd or wrong-atom value here would silently fall through since `WebSockAdapter.upgrade/4` isn't checked for a valid module.
  - `GET /healthz` → 200 "ok" — trivial but is the liveness-probe contract; a regression here is invisible until deploy.
  - The catch-all `match(_, do: send_resp(conn, 404, "not found"))` — untested, easy to accidentally shadow with a future route added above it.
  - Note: `GET /ws` itself can't be fully tested via `Plug.Test` (no actual WS upgrade handshake in the plain-Plug pipeline), but the handler-resolution logic feeding into it can be — e.g. assert `Application.put_env(:live_dj, :socket_handler, LiveDJ.Minimal)` changes which module conn info reflects before the upgrade call, or refactor the `Application.get_env` lookup into a small testable helper if finer-grained coverage is wanted.
  - **Recommendation: add `test/live_dj/router_test.exs`** using `Plug.Test.conn(:get, "/healthz") |> LiveDJ.Router.call([])` and the 404 catch-all — this is the single highest-value addition, cheap and exercises real deploy-relevant logic. Severity: **Warning** (not Critical — no user-facing regression risk today, but it's the one module with untested branching logic and no justification for skipping it).

- **`LiveDJ.config/0`** (lib/live_dj.ex:25-31) — zero direct tests. It's three `Application.get_env/2` calls with no defaults (unlike `Application.port` in `application.ex` which defaults to 8000, `config/0`'s three keys have no fallback and will return `nil` if unset). No test exercises the case where `:model`/`:voice`/`:port` are unset. **Minor gap** — low value to test in isolation (it's a thin wrapper), but worth a one-line smoke test asserting the keys exist post-config-load, since both `Socket.init/1` and `Minimal.init/1` depend on it silently returning `nil` rather than raising if misconfigured.

## 2. Flake Risk — Timing Assertion in tools_test.exs

**File:** `test/live_dj/tools_test.exs:37-56`, describe block `"the instant-return rule"`.

- Uses `:timer.tc/1` (wall-clock, not `System.monotonic_time/1` — `:timer.tc` is itself backed by monotonic time internally in modern OTP, so this is not a correctness bug, just worth noting it's not explicit).
- Threshold: `@budget_us 1_000` (1ms) for the sum-total of `Tools.dispatch/2` for 4 calls, each independently checked against the same 1ms budget (not summed).
- `Tools.dispatch/2` is a handful of pattern-matched map constructions — realistically it executes in low single-digit microseconds. Headroom is roughly **100–1000x** under normal conditions, which is generous, but this is precisely the kind of test that is silent 99.9% of the time and then fails exactly once, non-deterministically, on a loaded CI runner (GC pause, scheduler contention, noisy-neighbor VM) — a classic flake with no way to reproduce locally.
- **Severity: Warning** (not Critical — wide margin makes it low-frequency, but it violates Iron Law "no wall-clock timing assertions in CI" in spirit even though it doesn't use `Process.sleep`).
- **Recommended fix (preserves intent: dispatch must never do real work / block):** Replace the wall-clock threshold with a **structural/behavioral** guardrail instead of a timing one:
  1. Assert `Tools.dispatch/2`'s implementation contains no `receive`, `Task.await`, `GenServer.call`, or `:timer.sleep` — this can't easily be asserted from a black-box test, so the more practical version is:
  2. Keep a *much* looser timing assertion purely as a smoke check (e.g. `@budget_us 50_000` / 50ms) that only catches catastrophic regressions (an accidental `Process.sleep` or HTTP call), not micro-jitter — wide enough that CI noise can never trip it, while still catching "someone added a blocking call" class of regression.
  3. Better: add a dedicated unit-level guard — since the whole point is "no GenServer call, no HTTP, no Task.await", consider a lightweight static check (e.g. grep/Credo custom check on `lib/live_dj/tools.ex` for forbidden calls) as a compile-time or CI-lint guardrail instead of a runtime timing assertion, and demote the runtime check to a loose smoke test as in (2).
  - Do not remove the test entirely — the comment ties it to DESIGN.md §10 and it does encode a real design invariant; just widen the threshold by 10-50x to eliminate flake risk while keeping it useful as a canary for accidentally-blocking code.

## 3. Test Quality — socket_test.exs struct usage

- `socket_test.exs` constructs **real `gemini_ex` structs**: `%Gemini.Types.Live.ServerMessage{}`, `%ServerContent{}`, `%ToolCall{}` (verified against `deps/gemini_ex/lib/gemini/types/live/{server_message,server_content,tool_call}.ex`) — not hand-rolled maps standing in for them. This is good: it means a `gemini_ex` upgrade that renames/removes a struct field will fail these tests at compile/match time rather than silently drifting.
- One nuance worth flagging: `model_turn` (server_content_test fixtures, e.g. line 21) and each `part` (line 24, `%{inline_data: ...}`) are **plain maps, not structs** — this matches the library's own typespec (`ServerContent.content :: %{optional(:role) => ..., optional(:parts) => [map()]}` and `ServerContent.parse_content/1` builds `%{role: ..., parts: ...}` as a plain map, not a struct), so this is *not* a drift risk — it's an accurate reflection of the library's actual on-the-wire shape.
- `ToolCall.function_calls` entries in `socket_test.exs` (lines 121, 133-135, 146, 155) are plain maps with atom keys `%{id: ..., name: ..., args: ...}` — this **exactly matches** `Gemini.Types.Live.ToolCall`'s documented `@type function_call` and what `ToolCall.from_api/1` actually produces (atom-keyed maps, not string-keyed). No drift risk found here either.
- **No issues found in this section** — the tests are well-anchored to the real library shape, better than the audit brief's default suspicion suggested. One line item: no test constructs a `ToolCall` via `ToolCall.from_api/1` (the actual parse path used in production when a real API response arrives) — all tests hand-build the struct directly. This means a change to `from_api/1`'s parsing logic (e.g. a key rename in the raw API JSON) would not be caught by these tests. **Suggestion, not a defect:** add one test that round-trips `ToolCall.from_api(%{"functionCalls" => [%{"id" => "x", "name" => "skip", "args" => %{}}]})` into `Socket.handle_tool_call/2` to cover the actual deserialization boundary, not just the post-parse struct shape.

## 4. mix.exs elixirc_paths(:test) — Dead/Misleading Config

**File:** `mix.exs:22` — `defp elixirc_paths(:test), do: ["lib", "test/support"]`

Confirmed: `test/support/` **does not exist** (Glob returned no files). This is harmless today (Elixir/Mix silently no-ops a missing path in `elixirc_paths`) but is **misleading boilerplate** — it signals "there is test support infrastructure here" (factories, case templates, etc.) when there is none, and was almost certainly copied from a Phoenix-generated `mix.exs` without pruning. Since this project has no DataCase/ConnCase/factories to justify a `test/support` dir, either:
- remove the `:test` clause of `elixirc_paths/1` entirely (collapse to a single `defp elixirc_paths(_), do: ["lib"]`), or
- create `test/support/` only if/when shared test helpers are actually introduced.
**Severity: Suggestion** (cosmetic, zero functional impact).

## 5. Missing Tooling / Async Audit

- No `excoveralls` (or any coverage tool) in `mix.exs` deps — **not flagging as a gap requiring Phoenix/DataCase-style infra**, just noting coverage is unmeasured; given only 4 lib modules of real logic (`Tools`, `Socket`, `Persona`, `Router`) this is low-risk but coverage numbers would make the Router gap (finding #1) visible automatically.
- No `mix test --warnings-as-errors` invocation configured anywhere (no CI config file found in the repo to check against — if CI exists elsewhere, verify there).
- **Async audit:** all three test modules declare `use ExUnit.Case, async: true` (tools_test.exs:2, socket_test.exs:8, persona_test.exs:2) — correct, since none of them touch `Application.put_env`, global config, or shared processes. Confirmed no test mutates `Application.put_env(:live_dj, ...)` anywhere in the suite (grep confirms `LiveDJ.config/0`, which reads `Application.get_env(:live_dj, :model/:voice/:port)`, is **never called or tested directly**, and nothing in the three test files touches `:live_dj` app env). So `async: true` is currently safe everywhere. **Forward-looking note only:** if the Router test recommended in finding #1 is added and needs to exercise the `SOCKET_HANDLER` env-var swap (`Application.get_env(:live_dj, :socket_handler, ...)`), that test **must** either restore the env var in `on_exit/1` or run with `async: false`, since `Application.put_env/3` is process-global state shared across async test processes in the same VM.

## 6. Tautological / Assertion-Free Tests

None found. All 35 tests make a concrete, falsifiable assertion (pattern match or equality) tied to a specific input/output pair; none would pass if `Tools.dispatch/2`, `Socket.handle_info/2`, `Socket.handle_tool_call/2`, or `Persona.instruction/0` were deleted or their logic inverted — each asserts a specific shape or value derived from the module under test, not merely `assert true` or an unused binding.

## Summary of Clean Areas (no issues)
- Factory/build-vs-insert, Mox/behaviour mocking, Ecto sandbox, ConnCase/DataCase, LiveView render_async — all correctly N/A for this codebase's actual shape (no DB, no Phoenix, no Mox deps present).
- Test naming, `describe` grouping, and setup helpers (`state/0`, `audio_message/1`) are used appropriately in socket_test.exs.
- Persona and Tools tests are focused, fast, and free of shared/global state.
