# Architecture Audit — live-ceci (plain OTP, no Phoenix)

Scope: `lib/` (10 modules, ~1060 LOC per `wc -l`) and `config/`. POC stage per project
context; findings ranked P1 (fix before anything ships)/P2 (fix soon)/P3 (hygiene, low
urgency).

## 1. Provider behaviour seam (`lib/live_ceci/provider.ex`, `provider/gemini.ex`, `provider/grok.ex`)

**Clean.** The abstraction is honest. `@callback`s (`open/1`, `send_audio/2`, `close/1`)
cover only what is actually uniform between Gemini and Grok — session lifecycle and the
one hot-path call. The moduledoc's reasoning for omitting `send_tool_result/3`
(`lib/live_ceci/provider.ex:24-32`) checks out against both implementations:

- `provider/gemini.ex:87-97` — `handle_tool_call/2` returns `{:tool_response, responses}`
  as the return value of `gemini_ex`'s `on_tool_call` callback (synchronous, in-process).
- `provider/grok.ex:166-178` — the same decision (`LiveCeci.Tools.dispatch/2`) is reached
  via `translate/2`, but the result has to go back as *two* outbound WebSocket frames
  (`provider/grok.ex:189-197`), sent asynchronously over the wire, not returned to a
  caller.

A shared `send_tool_result/3` genuinely could not paper over that difference without a
protocol-specific escape hatch, which would defeat the point of the seam. No finding
here — noting only because the prompt asked for a judgment, not because there's an issue.

## 2. `provider.ex` <-> `provider/grok.ex` xref cycle

**P3 — cosmetic, not worth breaking.**

`mix xref graph --format cycles` reports the 2-cycle: `provider.ex` depends on
`provider/grok.ex` (the `Application.get_env(:live_ceci, :provider, LiveCeci.Provider.Grok)`
default at `lib/live_ceci/provider.ex:68`), and `provider/grok.ex` depends on `provider.ex`
(`@behaviour LiveCeci.Provider` at `lib/live_ceci/provider/grok.ex:24`, plus the
`@doc`/`@spec` reference back to the behaviour).

This is a compile-time edge (`mix xref graph --format stats` counts it as an outgoing
edge from `provider.ex`, not a runtime-only reference), so Mix will recompile both
modules together on either one's change. At 69 + 266 LOC that's free — no incremental
build pain, no runtime cost (behaviours are checked at compile time only), and no
dialyzer noise. The two modules are conceptually paired (the seam and its default
implementation) so coupling them is arguably correct, not accidental. Breaking it would
mean either (a) moving the default elsewhere, which just relocates the same knowledge, or
(b) deferring to config with no default, which weakens `MODEL` unset behavior for no
benefit. Leave it.

## 3. `LiveCeci.LiveSession` reaching into `gemini_ex` internals (`lib/live_ceci/live_session.ex`)

**P2 — real, acknowledged coupling; currently the least-bad option, but under-defended.**

Confirmed against `deps/gemini_ex` 0.17.0 (`deps/gemini_ex/lib/gemini/live/session.ex:237-239`):
the public `Session.send_realtime_input/2` is exactly `GenServer.call(session,
{:send_realtime_input, opts})` with **no timeout parameter exposed** — the 5000ms default
is hardcoded by `GenServer.call/2`'s own default, not by gemini_ex choosing it explicitly.
`lib/live_ceci/live_session.ex:33-37` reconstructs that same `{:send_realtime_input, opts}`
tuple by hand to pass a 1000ms timeout instead. The message shape happens to match
`handle_call/3` at `deps/gemini_ex/lib/gemini/live/session.ex:448` today.

Issues:
- The module's own comment (`live_session.ex:31-32`) says this is *why* `mix.exs` pins
  `gemini_ex` to `~> 0.17.0` — but that pin is not a real safety net. `~> 0.17.0` still
  allows 0.17.1, 0.17.2, etc., and nothing stops a 0.17.x patch from renaming the internal
  call tuple, changing its arity, or moving validation that currently lives in
  `handle_call/3` (e.g. the `:ready` state guard at `session.ex:448` vs. the fallback
  clause at `session.ex:461`) — a patch-level release is exactly where an internal
  message shape is allowed to change under semver. There is no test in this codebase (or
  possible to write) that would catch that at compile time; it fails silently as a
  changed `:error` term or a swallowed timeout.
- No comment/test documents *what breaks* if this drifts — only that it's fragile. Given
  the moduledoc already correctly identifies the exit-signal hazard as the reason this
  exists, the missing piece is a cheap tripwire: a test that asserts
  `Gemini.Live.Session` still exports whatever internal contract is being relied on (or at
  minimum, pin the dependency with an exact version `"== 0.17.0"` rather than `~>`, since
  the stated rationale — "one internal message" — only holds for the exact version
  inspected).

Given the POC framing this is acceptable to ship as-is, but it should not survive to
production without either (a) upstreaming a `timeout` argument to `gemini_ex` publicly, or
(b) tightening the version pin to match what the comment claims.

## 4. Tool dispatch inside each provider vs. the socket

**Clean, same reasoning as #1.** `lib/live_ceci/tools.ex` centralizes the actual decision
(`dispatch/2`), and each provider only owns the protocol-specific handshake around it —
`provider/gemini.ex:88-97` calls it inline inside a synchronous callback,
`provider/grok.ex:166-178` calls it inline inside `handle_frame`/`translate`. Moving
dispatch to the socket process would add a hop with no payoff (`socket.ex` never touches
tool args today) and, per the Gemini path, isn't possible anyway — the return value has
to come from the same process the callback runs on. No finding.

## 5. Module boundaries generally

**Mostly clean.** One dependency-declaration finding:

- **P3** — `mix.exs:30` declares `{:websockex, "~> 0.4"}` while `mix.lock` resolves
  `0.5.1` (forced by `gemini_ex`'s own tighter `{:websockex, "~> 0.5.1"}`).

  > **Correction, applied by the orchestrator after verification.** This finding
  > originally claimed `"~> 0.4"` means `>= 0.4.0 and < 0.5.0` and therefore does not
  > permit the locked `0.5.1`. That is wrong. `~> MAJOR.MINOR` on a two-segment
  > requirement means `>= 0.4.0 and < 1.0.0`; only a three-segment `~> 0.4.1` would stop
  > at `< 0.5.0`. Checked directly: `Version.match?("0.5.1", "~> 0.4")` returns `true`.
  > There is no conflict between `mix.exs` and `mix.lock`.

  What survives is the weaker, real point, which `deps-audit.md` states correctly: the
  constraint is LOOSE for a pre-1.0 package. `"~> 0.4"` admits the whole `0.x` line up to
  `1.0.0`, and this app depends on `WebSockex.send_frame/3`'s timeout argument
  (`provider/grok.ex:276`). Today only `gemini_ex`'s tighter requirement keeps the
  resolution on `0.5.x`; if that dependency were removed or loosened, `mix deps.get`
  could legitimately resolve back to `0.4.x`. Fix: declare `"~> 0.5.1"` so the file
  states its own requirement rather than relying on a transitive one.

No other boundary issues: `LiveCeci.Tools`, `LiveCeci.Persona`, `LiveCeci.Router`,
`LiveCeci.Application` each own one concern, none reach into another's private state,
and `LiveCeci.Socket` (`lib/live_ceci/socket.ex`) only calls the `Provider` behaviour
contract — it never pattern-matches on `Gemini.*` or Grok-specific structures itself
(that logic correctly stays inside each provider module, per the moduledoc at
`socket.ex:11-16`).

## Summary of findings

| # | Severity | Location | Issue |
|---|----------|----------|-------|
| 3 | P2 | `lib/live_ceci/live_session.ex:33-37`, `mix.exs:36` | Reimplements gemini_ex's internal `{:send_realtime_input, opts}` GenServer.call to get a custom timeout; `~> 0.17.0` pin doesn't actually prevent the patch-level drift the code's own comment worries about |
| 5 | P3 | `mix.exs:30` | `websockex "~> 0.4"` declared but `0.5.1` is what's locked/used and required by `gemini_ex`; the app's own constraint doesn't reflect the API it calls |
| 2 | P3 | `provider.ex:68` <-> `provider/grok.ex:24` | 2-node xref cycle; compile-time coupling between the seam and its default backend — harmless at this size, not worth restructuring |

Areas checked with nothing to report: Provider behaviour honesty (#1), tool dispatch
placement (#4), general module cohesion (#5 beyond the dep-constraint issue), Socket's
process/supervision model (one-process-per-connection, `trap_exit`, no bare receive
loop), and config/runtime.exs (no secrets logged, MODEL branch has independent defaults
per provider as documented).
