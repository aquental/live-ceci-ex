# Project health — live-ceci-ex — 2026-08-29 (re-run)

**Grade: B (80/100 weighted).** Essentially flat against this morning's B (81), and that
is the finding, not a null result.

Thirty commits landed between the two runs. Every P1, P2 and P3 from the first audit is
closed, including all three security items that had been deferred. The score did not
move because **fixing them created two new P1s, and both are self-inflicted.**

Same scoring caveat as the first run: the plugin's rubric is built for Phoenix/Ecto and
most of Performance and half of Security are inapplicable here. Categories are scored on
applicable criteria and renormalised. Compare this to the run above it, not to another
project.

---

## Scores

| Category | Now | This morning | 2026-08-28 |
|---|---:|---:|---:|
| Architecture | 92 | 95 | 90 |
| Dependencies | 90 | 95 | 92 |
| Test quality | 86 | 88 | 80 |
| Performance | 72 | 80 | 20 |
| Security | 70 | 62 | 5 |
| **Overall** | **80 · B** | 81 · B | 57 · C |

Security is the only category that rose. Three categories fell slightly, all for the
same reason: this run went looking at the code the last run caused.

---

## The headline: two auditors contradict each other, and both are right

**Performance P1** — `lib/live_ceci/live_session.ex:33`. Gemini's microphone path is
still a blocking `GenServer.call` on the socket process, up to 1 s per frame, ten times
a second, on the process that also pushes her voice downstream.

**Security P1** — `lib/live_ceci/provider/grok.ex:98`. Grok's path is *not* blocking any
more, and that is the problem: `WebSockex.cast/2` never blocks, Bandit reads at loopback
speed, and the WebSockex process drains at WAN speed. One authorised session pumping
1 MB frames grows that mailbox until the VM is OOM-killed.

These are the same fact seen from two ends. Commit `63d9b77` converted Grok's
`send_audio` to a cast to stop it stalling the socket — and **removed backpressure
without replacing it with a bound**. Downstream got a shed (`@max_queued 40`); upstream
got nothing. Gemini is immune to the second problem for exactly the reason it has the
first one.

The answer is neither auditor's: it is async **plus** an explicit bound, on both
providers. `LiveCeci.LiveSession` becoming a process per session — casts in, blocking
call inside — gives Gemini the same shape, and both then need a queue depth check.

That also corrects something I said twice: that the Gemini coupling was "not fixable
from inside this repo". `gemini_ex` genuinely has no cast path, which is true and was
not the whole story. What changes is not whether it blocks, but *which process waits*.

## The second headline: the ticket system introduced a denial of service

`lib/live_ceci/tickets.ex:63`. `@max_outstanding 200` is global, and it refuses the
**newest** rather than evicting the oldest. Reproduced:

```
250 issues from one address -> 50 refused, table full at 200
a legitimate user from another address -> {:error, :too_many}
```

A loop with a forged `Origin` fills it in well under a second and everyone else is
locked out. That bound was added to stop an unauthenticated endpoint growing a table
without end — a real concern — and the shape chosen turned a memory bound into an
availability weapon.

One correction to the report: it says the lockout is *indefinite*. It is not. Tickets
carry a 30 s TTL and `issue/1` sweeps, so the table clears 30 s after the flood stops.
It is a sustained-attack denial, not a permanent one. That does not rescue the design —
per-address buckets and evict-oldest both fix it — but the report overstated it.

## The third: I fixed a bug and did not check its sibling

`lib/live_ceci/provider/gemini.ex:28`. Verbatim the leaked-billed-session bug fixed in
`grok.ex`, comment and all, in the provider I did not look at:

```elixir
with {:ok, session} <- Session.start_link(session_opts(opts)),
     :ok <- Session.connect(session) do
```

If `connect/1` fails, `session` is dropped and the upstream session stays open and
billed. Worse than the Grok version was: the `Sessions` slot is keyed to the socket pid,
so a session leaked this way is invisible to the cap that exists to bound them.

---

## Everything else, by category

**Architecture (92).** One P2: admission control is split. Origin and ticket reject with
a plain 403 before the upgrade; the session cap upgrades first and then closes with
1013. Verified the premise — `bandit/http1/handler.ex:72` returns
`{:switch, Bandit.WebSocket.Handler, state}`, so ThousandIsland swaps the handler module
inside the same process and `self()` is identical either side of the upgrade. Moving
`Sessions.join/1` into the router would work and would make all three checks consistent.
The trade against it: a slot claimed in the router belongs to a process that has not yet
committed to being a session, and HTTP keep-alive can hold it.

The auditor also answered a question I asked it directly, and answered it well:
`commit_turn/1`'s Gemini no-op is **not** the same mistake as the absent
`send_tool_result/3`. That one had two incompatible handshake shapes forced into one
signature; this one has a shape both providers can implement, and the no-op is a
measured policy choice.

**Tests (86).** Three P1s, all in the tests I wrote this session, all about the same
thing: `sessions_test.exs` and `socket_lifecycle_test.exs` share one singleton
`Sessions` GenServer with no hard reset between them, and the `on_exit` cleanup kills
holder pids without waiting for the monitors to reap them.

Honest qualifier the report does not carry: **I could not make it fail.** Eight seeds of
the full suite and fifteen runs of the two files together, all green. It is a latent
race, not an observed one — which is exactly the profile of a test that passes for a
year and then fails once in CI.

**Dependencies (90).** No P1. The sharpest: `.formatter.exs` inputs are
`{config,lib,test}/**`, so `mix format --check-formatted` in CI **never looks at
`priv/`** — the spike scripts are outside the gate the CI was added to provide. Also
`:crypto` is used in `tickets.ex` and not declared in `extra_applications`; it works
today because something else starts it. And CI runs `deps.audit` but not `hex.audit`,
which check different things.

**Performance (72).** Beyond the P1 above, everything from the last run verified fixed.
`Sessions.join/1`'s per-upgrade `GenServer.call` and `Tickets.issue/1`'s per-mint sweep
were both examined and are trivial at these caps — off the audio path.

---

## Where the auditors were wrong

Two claims did not survive checking, and both are recorded in place rather than deleted:

- The ticket lockout is not *indefinite*; the 30 s TTL bounds it to the duration of the
  attack.
- Last run's `arch-review.md` claim that `~> 0.4` cannot resolve `0.5.1`, and
  `security-audit.md`'s claim that `get "/"` was dead code shadowed by `Plug.Static`,
  are annotated retractions from this morning. `Plug.Static` has no `:index` option at
  all, which is why acting on that finding turned the front page into a 404.

---

## Action plan

**Fix now — both are regressions this project introduced:**

1. Bound the upstream path. Async is right; async without a bound is what
   `63d9b77` shipped. Shed or block past a queue depth, on both providers.
2. Make `/ws-ticket` evict-oldest and bucket per address, so a bound on memory stops
   being a lever on availability.
3. `gemini.ex open/1` — close the session when `connect/1` fails, as `grok.ex` does.

**Then, cheap and worth it:**

4. `.formatter.exs` inputs to include `priv/**`, so CI actually checks what it claims to.
5. Declare `:crypto` in `extra_applications` rather than relying on a transitive start.
6. Add `mix hex.audit` and a `mix xref --format cycles` gate to CI while the graph is
   13 modules and clean.
7. Give `sessions_test.exs` a hard reset and a `total() == 0` precondition.

**Still open by decision or by reach:** every word spoken reaches the provider and is
transcribed there — the operational-only boundary governs what Ceci writes down, not
what she hears. And the false-turn rate of manual turn detection remains unmeasured: one
clean two-minute browser session is a good sign and not a measurement.
