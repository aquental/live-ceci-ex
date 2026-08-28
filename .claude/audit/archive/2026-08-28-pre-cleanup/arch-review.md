# Architecture Audit — live-dj (plain Elixir OTP + Plug/Bandit)

Scope: `lib/live_dj.ex`, `lib/live_dj/application.ex`, `lib/live_dj/router.ex`,
`lib/live_dj/socket.ex`, `lib/live_dj/minimal.ex`, `lib/live_dj/tools.ex`,
`lib/live_dj/persona.ex`, `lib/live_dj/gotcha.ex`, `config/config.exs`,
`config/runtime.exs`, `mix.exs`.

`LiveDJ.Minimal` and `LiveDJ.Gotcha` are intentional teaching duplicates/dead
code (per design) and are excluded from duplication/dead-code findings.

---

## Findings

### 1. [HIGH] `init/1` failure path leaves a zombie WebSocket open indefinitely
**File:** `lib/live_dj/socket.ex:78-81`

```elixir
{:error, reason} ->
  Logger.error("failed to open Live session: #{inspect(reason)}")
  {:push, error_frame(reason), %{session: nil}}
```

`WebSock.handle_result` for `init/1` supports `{:stop, reason, close_detail(),
messages(), state()}` (confirmed in `deps/websock/lib/websock.ex:81`), i.e. a
combined "send a frame, then close" return. This code instead uses
`{:push, ..., state}`, which keeps the socket process alive with
`state.session == nil`.

Trace what happens next: `handle_in/2`'s only binary-frame clause is guarded
by `when session != nil` (socket.ex:87), so with `session: nil` every binary
frame falls through to the catch-all `def handle_in(_frame, state), do:
{:ok, state}` (socket.ex:104) — a silent no-op, forever. Since the browser's
AudioWorklet streams mic PCM continuously once connected, those frames keep
arriving and (depending on the transport) can keep resetting any idle timer,
so the connection may never hit the `timeout: 60_000` set in
`router.ex:27` either. The result: on a Live-session open failure, the
browser receives one error frame, then the socket sits open and inert with
no way to self-terminate.

**Fix:** Return a combined stop tuple so the error frame is delivered and the
connection is torn down in the same step, e.g.:
```elixir
{:error, reason} ->
  Logger.error("failed to open Live session: #{inspect(reason)}")
  {:stop, :normal, 1011, error_frame(reason), %{session: nil}}
```

---

### 2. [MEDIUM] `LiveDJ.config/0` is a hard global-env dependency read inside `init/1`
**Files:** `lib/live_dj.ex:25-31`, `lib/live_dj/socket.ex:47`,
`lib/live_dj/minimal.ex:29,33`

`config/0` calls `Application.get_env/2` directly (no default, no injection
point), and both `Socket.init/1` and `Minimal.init/1` call it straight from
inside the WebSock callback. There's no way to supply per-test or
per-connection config without mutating global application env, which is a
testability hazard (any `async: true` test touching `:live_dj` config keys
races with every other such test) and couples socket construction to
process-global mutable state rather than to `init/1`'s `opts` argument (which
is currently discarded — `init(_opts)`).

**Fix:** Thread config through `opts` (e.g. `WebSockAdapter.upgrade(conn,
handler, LiveDJ.config(), ...)` in the router, then `init(opts)` reads from
`opts` with `LiveDJ.config()` only as its fallback). This keeps the global
accessor as a default but makes the socket testable with an explicit map.

---

### 3. [LOW] `handle_tool_call/2` mixes transport plumbing with domain response-shaping
**File:** `lib/live_dj/socket.ex:158-177`

`handle_tool_call/2` lives on `Socket` (correctly, since it must know the
`owner` pid to `send/2` a `:play` message — a transport concern), but it also
owns the domain-level iteration over `function_calls` and the shaping of the
`%{id:, name:, response:}` tool-response list, which is pure decision logic
that has nothing to do with the socket/transport. `LiveDJ.Tools` already owns
`dispatch/2`; the per-call mapping and response-list construction reads more
naturally as `LiveDJ.Tools.dispatch_all/2`, leaving `Socket.handle_tool_call/2`
as a one-line delegation plus the `send(owner, ...)` side effect.

**Fix (optional/style):** Move the `Enum.map` body into
`LiveDJ.Tools.dispatch_all(calls, on_command)` (with `on_command` as the
`send/1` callback) or return `{commands, responses}` and let `Socket` just do
the sends. Not required for correctness — flagging as a seam-placement nit
only.

---

### 4. [LOW-MEDIUM] `socket.ex` cohesion — one module, five concerns
**File:** `lib/live_dj/socket.ex` (200 lines)

The module currently owns: (a) session lifecycle (`init/1`, `terminate/2`),
(b) upstream frame handling, (c) downstream frame handling for five distinct
message shapes (`:gemini`, `:transcription`, `:play`, `:gemini_error`,
`:gemini_closed`, `:EXIT`), (d) tool-call dispatch glue, and (e) frame
encoding helpers (`voice_frames/1`, `interrupted_frame/1`, `json/1`,
`error_frame/1`, `transcript_role/1`). At 200 lines this isn't yet a God
object, but the outbound-frame-encoding helpers in particular (lines
181-199) are a self-contained, independently-testable unit doing wire-format
shaping rather than session/transport orchestration.

**Fix (optional):** Extract the frame-encoding private functions into a
small `LiveDJ.Socket.Frames` (or similar) module. Low priority for a demo of
this size — noting for awareness if the module grows further.

---

### 5. [MEDIUM] `Gemini.Live.Session` is an unsupervised linked process — correctness relies entirely on manual `trap_exit` bookkeeping
**File:** `lib/live_dj/socket.ex:44-46,73-76,139-142`

`Session.start_link/1` is called directly from `init/1` with no supervisor;
its only lifecycle guarantee is the implicit link to the socket process, made
safe-ish by `Process.flag(:trap_exit, true)`. This is a defensible design for
a 1:1 "one socket = one session" pairing (a restart wouldn't make sense — a
new session has no relation to the dead one), but it means correctness
depends entirely on the `{:EXIT, pid, reason}` clause matching by exact pid
(socket.ex:139). If `Session.start_link/1` itself returns `{:error, reason}`
(handled), fine — but if the session process is later replaced/reassigned in
`state` by any future code path without also updating what pid `handle_info`
expects to match, an `:EXIT` would silently fall through to the catch-all
`handle_info/2` clause (socket.ex:144-147), which only logs at `:debug` and
leaves the state stale. Today's code doesn't hit this (state.session is
never reassigned to a different pid), but the invariant ("state.session pid
must always equal the currently-linked Session pid, or be nil") is enforced
only by convention, not structurally.

**Fix:** No action required today, but if `Socket` ever grows
reconnect/retry logic, guard the invariant explicitly (e.g. assert-match on
reassignment, or use `Process.monitor/1` + a stored `ref` instead of matching
on `pid` to avoid any ambiguity from pid reuse).

---

### 6. [LOW] Unreachable defensive `terminate/2` clause
**File:** `lib/live_dj/socket.ex:150-156`

```elixir
def terminate(reason, %{session: session}) do
  ...
end

def terminate(_reason, _state), do: :ok
```

Every `state` value ever produced by this module is `%{session: _}` (set in
`init/1`'s two branches, and never restructured elsewhere), so the second
clause is dead code. Harmless, but slightly misleading as a "defensive"
fallback that can't actually trigger.

**Fix:** Either remove the second clause, or add a comment noting it exists
only as a contract-safety net against a hypothetical future `state` shape
change.

---

### 7. [LOW] Misleading log ordering in `Application.start/2`
**File:** `lib/live_dj/application.ex:15-19`

`Logger.info("live-dj listening on http://localhost:#{port} ...")` fires
*before* `Supervisor.start_link/2` — so on a bind failure (e.g. port already
in use), the log claims the server is listening when it never started.

**Fix:** Move the log line after a successful `Supervisor.start_link/2`, or
log "starting" pre-call and "listening" post-call.

---

## Clean areas (one line each, no action needed)

- Supervision topology itself (single `{Bandit, ...}` child, one_for_one) is
  a sound, idiomatic choice for this app's shape — no missing supervisor for
  anything that should be supervised at the `Application` level.
- `handle_in/2` and `handle_info/2` clause ordering, guards, and catch-alls
  are otherwise correct and total (no unmatched-message crashes).
- `@impl WebSock` annotations are present and correctly scoped across all
  clause groups in both `Socket` and `Minimal`; no behaviour-contract
  mismatches found against `deps/websock/lib/websock.ex`.
- `LiveDJ.Persona`'s `@external_resource`/compile-time read is correct and
  idiomatic.
- `LiveDJ.Tools.dispatch/2` is appropriately synchronous/side-effect-free per
  its own documented constraint (Live API tool calls must return instantly).
- `config/runtime.exs` ordering (env-var overrides applied after
  `config.exs` defaults, before app start) has no compile/runtime hazard.
