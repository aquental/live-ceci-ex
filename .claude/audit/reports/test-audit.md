# Test Health Audit — live-ceci-ex

Scope: 10 test files / 126 tests, plain Elixir OTP app (no Phoenix/Ecto/DB/Mox).
Known baseline (not re-litigated): `mix test` is 125/126 because `config/runtime.exs`
loads `.env` in `:test` too, and a local `PORT=8000` in `.env` beats `config/test.exs`.
`test/live_ceci_test.exs:18-19` is the only assertion currently pinned tightly enough
to catch it.

## P1 — Critical

- **config/runtime.exs:6-76 — `.env` loading is not gated by `config_env()`, and PORT
  is not the only value at risk.** Every value derived from `.env`
  (`PORT`, `MODEL`, `GOOGLE_LIVE_MODEL`/`GOOGLE_LIVE_VOICE`, `GROK_LIVE_MODEL`/`GROK_LIVE_VOICE`,
  `LANGUAGE`, `SILENCE_DURATION_MS`, `FRAME_SAMPLES`) is read unconditionally for every
  `config_env()`. Only the missing-API-key `IO.warn` (line 28) is conditioned on
  `config_env() != :test`. A developer's local `.env` can silently change the model,
  voice, language, or latency knobs the test suite boots with — not just the port.
  This is the same bug class as the known PORT failure, just not yet triggered because
  nobody's local `.env` currently sets `MODEL=GOOGLE` or a custom `SILENCE_DURATION_MS`
  while running tests. Fix: skip the `.env` read entirely when `config_env() == :test`
  (or explicitly `System.delete_env` the risky keys before that block), the way
  `config/test.exs` already does for `port`.

- **test/live_ceci_test.exs:38-45 — the tests that *should* catch #1 are too loose to
  catch it.** `"both knobs are present and inside the range runtime.exs accepts"` only
  asserts `is_integer(silence) and silence in 0..10_000` / `frame in 160..16_000` —
  any locally-overridden but in-range value passes silently. Same shape for model/voice
  at lines 9-10 (`is_binary(model) and model != ""`). The port test at line 18-19 is the
  *only* one in this describe block pinned to an exact literal, which is the only reason
  it alone failed and got the bug diagnosed. Recommend pinning model/voice/silence/frame
  to the literal values `config/test.exs` + a `.env`-free runtime should produce, so a
  future `.env` leak fails loudly instead of by chance.

## P2 — Warnings

- **test/live_ceci/provider/grok_test.exs:193-197 and :293-297 — `Process.sleep(20)`
  used to wait for process death.** `spawn(fn -> :ok end)` then `Process.sleep(20)` then
  `refute Process.alive?(pid)` is a timing assumption disguised as a fact — under
  scheduler pressure (126 tests, many async) 20ms is not guaranteed. The same file
  demonstrates the correct pattern two tests later (`close/1`, line 285-291, and
  `live_session_test.exs:42-52`, which uses `Process.monitor/1` +
  `assert_receive {:DOWN, ...}`). Replace both sleeps with a monitor + `assert_receive`.

- **test/live_ceci/tools_test.exs:98-111 — `@budget_us 50_000` wall-clock assertion is a
  genuine flakiness source**, acknowledged in the test's own comment ("it also sees every
  unrelated stall on the machine"). With reductions now covering the "does real work"
  half (lines 113-125), the wall-clock half only needs to catch *blocking* calls, which
  are orders of magnitude past 50ms — so the risk is asymmetric (rare false failures,
  never false passes) but still real on a loaded CI box or a dev machine under load.
  Consider whether the wall-clock half still earns its keep given the reduction budget
  now exists, or widen it further (e.g. 200ms) since the failure modes it's guarding
  against (GenServer.call, HTTP, sleep) all blow past any reasonable budget anyway.

- **Shared global `Application` env mutated by `async: false` tests, read by `async: true`
  ones — fragile, not currently broken.** `test/live_ceci_test.exs` (async: false) mutates
  `:live_ceci, :voice` at lines 30/33, and `test/live_ceci/socket_lifecycle_test.exs`
  (async: false) mutates `:live_ceci, :provider` at line 42. Meanwhile
  `test/live_ceci/router_test.exs:34-42` (async: true) calls `LiveCeci.config()` — today
  it only reads `frame_samples` and compares it against itself, so it's immune, but
  nothing prevents a future async test from reading `:voice` or `:provider` and
  intermittently observing the async:false test's temporary override. ExUnit does not
  guarantee async and non-async cases never overlap. No fix needed today; flag for
  whoever adds the next `LiveCeci.config()`-reading test.

## P3 — Suggestions

- **test/live_ceci/agent_name_test.exs:48-77 — the "no lingering mira" grep test is a
  brittle substring guard.** It regexes `~r/mira/i` across every file under `lib/`,
  `priv/frontend`, and one asset file. It's a legitimate regression guard for the specific
  failure mode described in the moduledoc (a missed CSS-class/atom rename that no
  compiler or unit test would catch) — but the pattern is a bare substring, not a
  word/token boundary. Any future code or copy containing "mira" as a substring
  (`admirar`, `mirante`, `admiração`, a comment quoting the old name for context) breaks
  the build for a reason unrelated to the actual regression. Narrow it to the specific
  tokens that mattered (`:mira`, `.mira`, `role="mira"`, `"mira"`) rather than the bare
  word.

- **Characterization tests earn their keep, but rely on human discipline to stay
  honest.** `grok_test.exs` `session_update/1` (lines 181-260) and `gemini_test.exs`
  `session_opts/1` (lines 110-188) both say outright they cannot prove the wire shape is
  right, only that nobody changed it by accident. Given `gemini_ex` is pinned to a minor
  (`mix.exs:37`) specifically because of prior transport changes, and Grok's protocol is
  hand-rolled against a spike rather than a published client, these are the *only* net
  protecting against silent wire drift — worth keeping, but note a deliberate/considered
  edit to either test (rather than a "make it pass" edit) is required whenever the pinned
  dependency version moves.

- **lib/live_ceci/application.ex has no dedicated test.** It's implicitly exercised
  because the whole app boots under `mix test` (per the comment in `config/test.exs`),
  but nothing asserts the supervision strategy or child spec, and the
  `Application.get_env(:live_ceci, :port, 8000)` fallback default (line 9) is dead code
  today since `runtime.exs` always sets `:port` — if that invariant ever broke, nothing
  would catch the silent fallback to `8000`. Low priority given the file is a two-line
  wrapper.

- **lib/live_ceci/router.ex:36-37 — the "reachable only because priv/frontend holds no
  file named config.json" invariant is documented but not tested.** If a `config.json`
  static file were ever added to `priv/frontend`, `Plug.Static` would shadow the
  `/config.json` route and the browser would silently stop getting `frameSamples`,
  reverting to the AudioWorklet's built-in default (per the comment at
  `router.ex:31-33`) — with no test failing. A regression test asserting the response
  actually contains `frameSamples` (which it already does, at
  `router_test.exs:34-42`) does *not* cover the shadowing scenario since no such static
  file currently exists to trigger it; consider a smoke test that fails if
  `priv/frontend/config.json` is ever created.

- **lib/live_ceci/provider/grok.ex:38-62 — `open/1`'s success path is entirely
  untested.** Only the missing-API-key branch is covered
  (`grok_test.exs:307-312`). The URL construction, the `WebSockex.start_link` success
  branch, and the `{:error, reason}` branch from a failed connect are all unverified —
  understandable given the "no network access" constraint, but worth naming as a known
  gap rather than assumed-covered.
