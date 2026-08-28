# Architecture Review — live_dj (2026-08-28)

Scope: plain Elixir/OTP app (Bandit + Plug.Router + WebSock + gemini_ex). No Phoenix,
Ecto, Oban, Ash, or LiveView findings apply — none exist in this codebase.

## Issues

### P3 — `lib/live_dj/application.ex:9` — duplicate, drift-prone config read for `:port`

`Application.get_env(:live_dj, :port, 8000)` reads `:port` directly instead of going
through `LiveDJ.config/0` (`lib/live_dj.ex:23-30`), which already exists as the single
documented accessor for `model`/`voice`/`port`. Two consequences:

- The `8000` default here is unreachable in practice (`config/config.exs:6` already sets
  `port: 8000`, and `config/runtime.exs:39` always sets it too), so it's dead code that
  will silently go stale if the config default ever changes.
- There are now two ways to read the same three config keys in the codebase — one via
  `LiveDJ.config/0`, one via a raw `Application.get_env/3` call — which is exactly the
  kind of inconsistency `LiveDJ.config/0`'s docstring exists to prevent.

**Fix**: `port = LiveDJ.config().port` (drop the redundant default, since config.exs and
runtime.exs both guarantee the key is set).

### P3 — stale references to deleted teaching modules outside the excluded archive

`.claude/audit/summaries/project-health-2026-08-28.md:53,63` still describes
`SOCKET_HANDLER`, `LiveDJ.Minimal`, and `LiveDJ.Gotcha` as live parts of the system
("are not dead code", "the SOCKET_HANDLER swap"). These were deleted from `lib/`,
`config/`, `test/`, and `README.md` earlier today (confirmed clean — no references
remain in those four locations), but this summary file lives under
`.claude/audit/summaries/`, not `.claude/audit/archive/`, so it isn't covered by the
historical-record exemption and will mislead anyone who reads it as current state.

**Fix**: either move this file into `.claude/audit/archive/` or update it to reflect
the deletion.

## Clean areas (one line each, per instructions)

- **Module boundaries / cohesion** (`lib/**/*.ex`): 6 modules, each single-purpose
  (`Application` boots one child; `Router` is pure HTTP surface; `Socket` is the
  bridge; `LiveSession` wraps one hazardous call; `Persona`/`Tools` are static data +
  dispatch). `mix xref graph` shows 0 cycles, 0 compile-time edges, socket.ex has the
  most outgoing deps (4) but they're all its actual collaborators (Gemini structs +
  LiveDJ.LiveSession/Persona/Tools) — no god-context, no reaching across boundaries.
- **Config layering** (`config/*.exs`): `config.exs` sets compile-time defaults,
  `runtime.exs` correctly overrides `model`/`voice`/`port`/API key from env at boot
  (release-safe), `runtime.exs`'s own fallback to `Application.get_env(:live_dj, :model)`
  correctly reads the already-loaded compile-time value rather than re-hardcoding it.
- **`lib/live_dj/socket.ex` concentration** (item 3): justified, not a split candidate.
  ~209 lines implementing one `WebSock` behaviour for one bounded concern (the
  browser<->Gemini bridge); `handle_in`/`handle_info`/tool dispatch all operate on the
  same single piece of state and share vocabulary. Splitting would add indirection
  (message-passing or a second process) with no concurrency/isolation benefit — would
  violate the OTP Iron Law against processes without a runtime reason.
- **OTP structure** (item 4): sound. Single `one_for_one` supervisor over Bandit;
  Bandit supervises one process per connection; `LiveDJ.Socket` explicitly
  `Process.flag(:trap_exit, true)` before `Session.start_link/1` so the linked Gemini
  session's death becomes a reportable `{:EXIT, ...}` message
  (`socket.ex:145-148`) instead of silently taking the connection down — correct use of
  linking to enforce "session dies with the connection."
- **`String.to_atom/1` in `lib/live_dj/tools.ex:77`**: not attacker-controlled — both
  call sites (`tools.ex:68,71`) pass the literal `"mood"`/`"title"`, confirmed by
  `mix compile --warnings-as-errors` and reading all callers; no atom-exhaustion path.
- **`mix compile --warnings-as-errors`** and **`mix format --check-formatted`**: both
  pass clean.
- **README.md / test/**: no stale references to the deleted `SOCKET_HANDLER`,
  `LiveDJ.Minimal`, or `LiveDJ.Gotcha`.
