# Test Health Audit — live-dj-ex

Scope: test/live_dj/socket_test.exs, tools_test.exs, router_test.exs, persona_test.exs,
live_session_test.exs, test/live_dj_test.exs, test/test_helper.exs (49 tests, all passing).
No `mix test --cover` run (no Bash tool available in this session) — coverage gaps below are
derived from reading lib/ against every test file line by line.

Clean areas (one line each, no further detail):
- async: true declarations are all safe — no async file touches Application.put_env or other
  shared global state; live_dj_test.exs is correctly the sole async: false file.
- Mocking is boundary-only: live_session_test.exs's `StubSession` stands in for the external
  `Gemini.Live.Session` GenServer contract, nothing internal or stdlib is mocked.
- No Process.sleep-based timing assertions anywhere; live_session_test.exs uses a genuine
  never-replies GenServer + explicit small timeout to force the timeout branch, not a race.
- Fix (a), persona file not reachable over HTTP, is directly regression-tested:
  router_test.exs:64-69 asserts 404 + body does not contain persona text.

## Issues Found

### Critical (P1)

- [ ] **lib/live_dj/socket.ex:91-105, test/live_dj/socket_test.exs (missing)** — The
  `handle_in({pcm, [opcode: :binary]}, %{session: session} = state) when session != nil`
  clause — i.e. the actual mic-audio ingestion path that calls `LiveDJ.LiveSession.send_audio/2`
  — has **zero** coverage in socket_test.exs. Only the text-opcode ignore case is tested
  (socket_test.exs:202-204). Neither the `:ok` branch nor the `{:error, reason}`
  (logged-and-swallowed) branch is exercised, and the `session: nil` fallthrough for a binary
  frame is untested too. A regression here (e.g. crashing instead of swallowing the error, or
  accidentally calling `send_client_content` instead of realtime input) would not be caught.
  **Add**: a `StubSession`-style GenServer replying `:ok` and one replying `{:error, _}` to
  `:send_realtime_input`, then assert `Socket.handle_in({pcm, [opcode: :binary]}, %{session: stub})`
  returns `{:ok, state}` in both cases; also assert the `session: nil` case falls through to the
  no-op clause instead of crashing on the guard.

- [ ] **lib/live_dj/socket.ex:42-86, test/live_dj/socket_test.exs (missing)** — `init/1` is
  never invoked by any test. This is the code path that opens the `Gemini.Live.Session` and,
  on failure, builds `{:stop, :normal, 1011, error_frame(reason), %{session: nil}}` — the
  **second** call site of `error_frame/1` (socket.ex:84, 202-204). Today's fix (b), "an error
  frame must not leak the upstream failure reason," is only regression-tested for the
  `handle_info({:gemini_error, reason})` downstream path (socket_test.exs:177-185). A regression
  that reintroduces `inspect(reason)` (or the raw reason) specifically into the init-failure
  frame would pass the entire suite untouched. **Add**: either make `error_frame/1` `@doc false`
  public and unit-test it directly against both known reason shapes, or drive `init/1` with a
  session_opts stub / dependency seam so the start_link-failure branch runs and its pushed frame
  is asserted not to contain the reason.

### Warnings (P2)

- [ ] **lib/live_dj/socket.ex:156-162, test/live_dj/socket_test.exs (missing)** — `terminate/2`
  (both clauses) is untested: no assertion that `Session.close/1` fires when `session` is an
  alive pid, and no assertion that the catch-all clause is a safe no-op when session is `nil` or
  the process is already dead. **Add**: a test with a live stub session asserting close is
  called (e.g. via `assert_receive`/monitor on the stub), and a test with `%{session: nil}`
  asserting `terminate/2` returns `:ok` without raising.

- [ ] **test/live_dj/socket_test.exs:130-143** — "several calls in one batch are all dispatched,
  in order" verifies list order for the returned `{:tool_response, [...]}` (real, via pattern
  match), but the two `assert_received {:play, ...}` calls that follow do not actually verify
  relative ordering between the two `{:play, ...}` side-effect messages — `assert_received` only
  checks mailbox presence, not position. The test name overclaims what's covered for that half.
  **Fix**: drain the mailbox in order (`assert_receive` sequence without pattern-matching
  ahead, or collect via `Process.info(self(), :messages)`) to actually assert ordering, or amend
  the test name/comment to admit only the response-list order is checked.

- [ ] **test/live_dj/router_test.exs (missing)** — No test exercises `GET /ws` with a malformed
  or missing WebSocket handshake (e.g. absent `sec-websocket-key`, wrong `upgrade` header
  value). Only the fully-valid handshake is tested (router_test.exs:72-80). If
  `WebSockAdapter.upgrade/4` starts crashing instead of rejecting a bad handshake cleanly,
  nothing in this suite would catch it. **Add**: a case sending `conn(:get, "/ws")` with no
  upgrade headers and asserting a non-crashing response (whatever WebSockAdapter's documented
  behavior is — likely a 400 or plain passthrough).

- [ ] **lib/live_dj/application.ex (no test file)** — `LiveDJ.Application.start/2`, including
  the `Application.get_env(:live_dj, :port, 8000)` default-fallback branch, has no dedicated
  test. Low priority (thin `Supervisor.start_link/2` wrapper started implicitly by `mix test`),
  but the literal default-port fallback is exercised by nothing in the suite since
  config/runtime.exs always sets `:port` in this repo's normal boot path.

### Suggestions (P3)

- [ ] **test/live_dj/tools_test.exs:59-84** — `@budget_us 50_000` and `@budget_reductions 40`
  are sound: both carry a >2x margin over the documented measured worst case (14 µs / 19
  reductions), and the reductions instrument is immune to machine load so it will not flake.
  No change needed; noting only because the prompt asked for an explicit evaluation.

- [ ] **test/live_dj/router_test.exs:54-58** — "the audio files the player streams are still
  served" only asserts `conn.status == 200`, not content-type or a non-empty body. A regression
  serving an empty 200 or the wrong content-type would slip through. Consider asserting
  `conn.resp_body != ""` at minimum.
