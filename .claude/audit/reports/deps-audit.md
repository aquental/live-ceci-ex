# Dependency Audit — live_dj

Date: 2026-08-28 · Elixir 1.20.3 / OTP 29 (erts 17.0.5) · 6 direct deps, 24 total

## Clean areas (one line each)

- **Vulnerabilities**: `mix deps.audit` → "No vulnerabilities found." `mix hex.audit` → "No retired or security advisory packages found."
- **Outdated**: `mix hex.outdated` reports all 6 direct deps **Up-to-date** (bandit 1.12.5, gemini_ex 0.17.0, jason 1.4.5, mix_audit 2.1.5, plug 1.20.3, websock_adapter 0.6.0). Nothing is behind.
- **Unused deps**: none. All six are referenced (`Bandit` in `application.ex`, `Plug.Router`/`Plug.Static` in `router.ex`, `WebSockAdapter.upgrade/4` in `router.ex`, `Gemini.*` in `socket.ex`/`live_session.ex`/`tools.ex`/`runtime.exs`, `Jason` in `socket.ex`, `mix_audit` as a mix task). `mix deps.unlock --check-unused` is clean — no stale lock entries.
- **Env/runtime settings**: `mix_audit` `only: [:dev, :test], runtime: false` is correct (mix-task-only, never called from `lib/`). All other deps are runtime deps used in the supervision tree or hot path — no wrong flags.
- **gemini_ex private-API coupling**: **verified — it still holds** on the vendored 0.17.0 source (details below).
- **Build**: `mix compile --warnings-as-errors --force` and `mix test` (49 tests) both pass on the installed 1.20.3/OTP 29.

## Item 5 — gemini_ex coupling verification (result: holds, no upgrade pending)

Verified against `deps/gemini_ex/lib/gemini/live/session.ex` @ 0.17.0:

- Public API, line 238: `def send_realtime_input(session, opts) do GenServer.call(session, {:send_realtime_input, opts}) end` — **arity 2, no timeout argument**, default 5 000 ms `GenServer.call` timeout. Confirmed at runtime: `Gemini.Live.Session.__info__(:functions)` exports `send_realtime_input: 2` only (no `/3`).
- Internal message, line 448: `def handle_call({:send_realtime_input, opts}, _from, %{status: :ready} = state)` with a fallback clause at line 461 returning `{:error, {:not_ready, status}}`. The shape `{:send_realtime_input, opts}` sent by `lib/live_dj/live_session.ex:33` **matches exactly**, and `opts` is a keyword list, so `[audio: blob]` is correct.
- `Gemini.Live.Audio.create_input_blob/2` (`deps/gemini_ex/lib/gemini/live/audio.ex:115`) is public, returns `%{data: pcm, mime_type: "audio/pcm;rate=16000"}` un-encoded by default — matches the assertion in `test/live_dj/live_session_test.exs`.
- No timeout escape hatch exists anywhere in the module: `send_client_content/3` and `send_text/3` also take an `opts` that is *message* options, not a call timeout (lines 192, 204). So there is still no public way to get the sub-second timeout the app needs.
- **Upgrade impact: none available.** 0.17.0 is the newest release on hex (released 2026-08-21); the lock is already at it. Nothing to assess yet.

Verdict: the pin's rationale and the code are consistent. The issue below is about how that coupling is *defended*, not about whether it currently works.

---

## Issues

### P2 — Nothing in the test suite would catch a gemini_ex upgrade that breaks the private-message coupling

`test/live_dj/live_session_test.exs` exercises `LiveDJ.LiveSession.send_audio/3` against a local `StubSession` GenServer that is hand-written to answer `{:send_realtime_input, opts}`. The stub *is* the contract — it will keep passing forever regardless of what the real `Gemini.Live.Session` does. `lib/live_dj/socket.ex` never calls the real session in tests either (it goes through `LiveDJ.LiveSession`).

Consequence: `~> 0.17.0` permits a 0.17.1 patch. If that patch renames the message, converts it to a cast, or routes through a Registry, `mix compile` stays clean (it is a bare `GenServer.call`, not a function call — nothing to warn about), all 49 tests stay green, and the failure surfaces only as a runtime `{:error, {:exit, {:timeout, ...}}}` per mic frame in production: silent dead air, exactly the failure mode `LiveDJ.LiveSession` was written to survive. The wrapper's own resilience hides the breakage.

Action — add a canary assertion to `test/live_dj/live_session_test.exs` that touches the *real* module, so an upgrade fails CI instead of the mic:

```elixir
test "gemini_ex still lacks a public timeout, so the private call is still required" do
  Code.ensure_loaded!(Gemini.Live.Session)
  # If an arity-3 send_realtime_input appears, upstream may have added a timeout —
  # re-check and drop the private-message hack in LiveDJ.LiveSession.
  assert function_exported?(Gemini.Live.Session, :send_realtime_input, 2)
  refute function_exported?(Gemini.Live.Session, :send_realtime_input, 3)

  # The handle_call clause LiveDJ.LiveSession sends to must still exist.
  source = File.read!("deps/gemini_ex/lib/gemini/live/session.ex")
  assert source =~ "handle_call({:send_realtime_input, opts}"
end
```

The source-grep half is deliberately brittle: that is the point — it is the only mechanical check available for a message shape that is not part of any exported function. Pair it with the existing comment in `mix.exs`.

### P3 — `websock` is used directly but declared only transitively

`lib/live_dj/socket.ex:34` declares `@behaviour WebSock` and uses `@impl WebSock` five times (lines 41, 90, 114, 155). `websock` (0.5.3) is nowhere in `mix.exs` — it arrives through `bandit` (`websock ~> 0.5`) and `websock_adapter` (`websock ~> 0.5`). The app compiles today only because both parents happen to require it.

This is the classic "missing direct dep": the version of the behaviour the socket implements is decided by someone else's requirement, and a resolution change (or swapping the adapter) silently changes or removes it.

Action — add to `mix.exs` deps, next to `websock_adapter`:

```elixir
{:websock, "~> 0.5"},
```

No lock change results (0.5.3 already resolved); it only makes the dependency explicit and version-controlled.

### P3 — `websock_adapter` constraint is looser than the project's own stated policy

`{:websock_adapter, "~> 0.5"}` resolves to **0.6.0** — the lock already crossed a pre-1.0 minor boundary, where breaking changes are permitted by convention. `~> 0.5` will keep accepting 0.7, 0.8 … up to 1.0.

`mix.exs` argues at length (correctly) that `~> 0.17` would be wrong for gemini_ex because a 0.x minor bump is a breaking-change slot, yet applies exactly that pattern to `websock_adapter`, whose `WebSockAdapter.upgrade/4` call in `router.ex:26` is the single entry point for every browser connection.

Action — tighten to match what is actually locked and tested:

```elixir
{:websock_adapter, "~> 0.6"},
```

### P3 — `~> 0.17.0` still admits patch releases that can change internal messages

The minor pin is right and the reasoning in `mix.exs` is sound, but a private GenServer message carries no semver promise at *any* level — 0.17.1 may legitimately rewrite `handle_call` internals. For an application (not a library), `mix.lock` is the real pin and only changes on an explicit `mix deps.update gemini_ex`, so this is a defence-in-depth point, not a live bug.

Action — either accept it and rely on the P2 canary test to catch a bad update (recommended: cheaper, and the test is needed regardless), or harden the constraint to `{:gemini_ex, "== 0.17.0"}` and extend the existing `mix.exs` comment to say the pin is exact because the coupling is to an unversioned internal message. Do not do the second without the first.

### P3 — Two transitive deps are frozen by gemini_ex's tight requirements

`mix hex.outdated --all` flags:

| Dep | Locked | Latest | Blocked by |
|---|---|---|---|
| `req` | 0.6.3 | **0.7.4** | `gemini_ex` requires `req ~> 0.6.2` |
| `joken` | 2.6.2 | **2.7.0** | `gemini_ex` requires `joken ~> 2.6.2` |

Both are "Update not possible". No advisory affects either today (`mix deps.audit` is clean), and neither is on live_dj's hot path — `req` is gemini_ex's REST client, `joken`/`jose` only serve Vertex service-account auth, which this app does not use (`runtime.exs` configures an AI Studio API key). The exposure is future: a `req` advisory could not be remediated without a gemini_ex release, and `req` is a full minor behind.

Action — no change now. Track it: if `mix deps.audit` ever flags `req` or `joken`, the fix is an upstream gemini_ex issue/PR, not a local `mix deps.update`. Worth a line in the `mix.exs` comment block so the next person does not waste time trying to bump them.

### P3 — No pinned toolchain; the declared floor is three minors below what is actually used

`elixir --version` → 1.20.3 / OTP 29. `mix.exs` declares `elixir: "~> 1.17"` (satisfied), README says "Requires Elixir `~> 1.17` (developed on 1.20 / OTP 29)". But there is **no `.tool-versions`**, no `.mise.toml`, no CI workflow, and **no OTP floor** declared anywhere.

So nothing verifies the 1.17 claim — the app has only ever been compiled and tested on 1.20/OTP 29. Anyone provisioning from the stated floor gets an untested combination, and `deps/` includes `bandit` 1.12 / `thousand_island` 1.5, which are themselves newer libraries.

Action — pick one and make it true:

1. Add `.tool-versions` recording the toolchain actually in use, so dev/CI/Docker agree:
   ```
   elixir 1.20.3-otp-29
   erlang 29.0.5
   ```
2. Either raise the `mix.exs` floor to what is genuinely supported (`elixir: "~> 1.17"` → keep only if you intend to test it), or leave it and treat 1.17 as a best-effort claim in the README rather than a guarantee.

### P3 (nit, non-dep) — `.dockerignore` exists with no `Dockerfile`

`.dockerignore` is present and carefully written (it excludes `.env` with a comment about `COPY . .`), but there is no `Dockerfile` anywhere in the repo and the README never mentions Docker. Either the image build was dropped or it was never added.

Action — add the `Dockerfile` or delete `.dockerignore`; a lone ignore file suggests a build that does not exist and will drift out of date if one is added later.

---

## Commands run

```
mix hex.outdated            # all 6 direct deps up-to-date
mix hex.outdated --all      # req + joken "Update not possible"
mix deps.audit              # No vulnerabilities found.
mix hex.audit               # No retired or security advisory packages found
mix deps.unlock --check-unused   # clean
mix xref graph --format stats    # 7 files, 0 compile edges, 0 cycles
mix compile --warnings-as-errors --force   # clean
mix test                    # 49 passed
```
