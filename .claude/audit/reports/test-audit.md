# Test Health Re-Audit — live-ceci-ex

Baseline: 88/B, 126 tests (2026-08-29). Now: 181 tests / 13 files, 83.92% coverage.
Scope: judge the two new files (`tickets_test.exs`, `sessions_test.exs`) and the
outstanding coverage/silent-breakage questions. Previously-fixed items are not
re-reported.

## P1

### 1. `sessions_test.exs` on_exit cleanup is fire-and-forget, not synchronous — isolation is not actually total
`test/live_ceci/sessions_test.exs:24-30`

```elixir
on_exit(fn ->
  for pid <- Agent.get(spawned, & &1), do: Process.exit(pid, :kill)
  Agent.stop(spawned)
  ...
end)
```

The unlinked `Agent.start/1` (not `start_link`) is the *correct* choice — a linked
Agent would die with the test process before `on_exit` runs, which is exactly the bug
the comment describes. But the cleanup itself only **sends** kill signals; it never
waits for the killed holders to actually die, and never waits for `LiveCeci.Sessions`
(a separate GenServer, notified via its own `Process.monitor/1` on each holder) to
process the resulting `:DOWN` and decrement its internal map. `on_exit` returns as
soon as the `for` loop finishes issuing exits, which can be before the GenServer has
reaped them.

This matters specifically because this is the path exercised on a **failing**
assertion mid-test (the comment literally says this mechanism exists so "a FAILING
assertion still releases its slots") — i.e. the one case where nobody else in the
test body is already polling for the release with `eventually/2`. Nothing downstream
(this file, or the next sync-phase file) waits for or asserts a clean baseline before
proceeding. In practice the GenServer reaps almost immediately, so this is unlikely to
be visibly flaky today, but it is not the "total" isolation the comments claim, and it
is the same race that afflicts finding #2 below.

Fix: after the kill loop, poll `Sessions.total()` (or a count scoped to the pids just
killed) back to a known baseline before returning from `on_exit`, e.g. reuse the
file's own `eventually/2`.

### 2. The "exactly 5 accepted" concurrency assertion assumes a clean `Sessions` baseline that nothing establishes or verifies
`test/live_ceci/sessions_test.exs:121-134`

```elixir
Application.put_env(:live_ceci, :max_sessions, 5)
...
assert length(accepted) == 5, "cap is 5 and #{length(accepted)} were accepted — ..."
```

`Sessions` is a single named GenServer shared by the whole test run (both within this
file and across `test/live_ceci/socket_lifecycle_test.exs`, see #3). The test never
asserts or resets `Sessions.total() == 0` before spinning up 40 concurrent joins. If
*any* holder from an earlier test/file has not yet been reaped (see #1 and #3), the
cap of 5 is reached with fewer than 5 of *this test's* 40 joins — the assertion
`length(accepted) == 5` fails on a correct implementation, i.e. a flake unrelated to
the property under test.

The core logic (GenServer serializes `join/1`, so under a clean baseline exactly 5
of 40 concurrent arrivals are accepted) is sound and does distinguish the fixed
design from the old Registry-based one (3 accepted). The problem is purely the
missing baseline guarantee. Fix: assert/force `Sessions.total() == 0` (or drain to it
with `eventually/2`) at the top of this test, not just rely on prior tests having
"probably" cleaned up.

### 3. Cross-file contamination: `socket_lifecycle_test.exs` and `sessions_test.exs` share the same singleton `Sessions` GenServer and the same default address, with no reset between them
`test/live_ceci/socket_lifecycle_test.exs:49-84`, `test/live_ceci/sessions_test.exs` (whole file)

`Socket.init([])` defaults `address` to `{127, 0, 0, 1}` (`lib/live_ceci/socket.ex:47`),
the same `@local` address `sessions_test.exs` uses throughout. `socket_lifecycle_test.exs`
calls `Socket.init([])` four times (two under `OkProvider`, two under `FailProvider`);
every one of them calls `Sessions.join/1` for real (there is no mock/stub for
`Sessions` — see also the note in #4) and holds a slot until the *test process*
itself exits (the monitored pid is the caller of `join/1`, i.e. the ExUnit test
process, not the spawned provider session — so this is not a permanent leak, but it
is reaped asynchronously and on nobody's schedule). Both files are `async: false`, so
ExUnit will run them one after another in the sync phase, but nothing sequences
"finish reaping `socket_lifecycle_test`'s holders" before "start `sessions_test`'s
first assertion of an exact count." `sessions_test.exs`'s first test
(`"sessions are refused once the total is reached"`) sets `max_sessions: 3` and
expects the 4th join across ALL addresses to be refused, with **no check that
`Sessions.total()` starts at 0**. A handful of not-yet-reaped holders from
`socket_lifecycle_test.exs` (or from a prior `describe` block in the same file, see
#2) will make this fail one join earlier than the test expects.

This is the concrete version of #1/#2's abstract race, and it is why "total
isolation" is the wrong claim for this file as written.

## P2

### 4. `sessions_test.exs` and `tickets_test.exs` exercise the real singleton, not a scoped instance — no way to reset between describe blocks except ad hoc polling
Both files rely on the *actual* running `LiveCeci.Sessions` / `LiveCeci.Tickets`
singletons (started by the application supervision tree) rather than starting a
private, uniquely-named instance per test. `tickets_test.exs` at least has a real
reset primitive (`:ets.delete_all_objects(Tickets)` in `setup`/`on_exit`,
`tickets_test.exs:13-14`) that fully clears state before every test — that one is
sound. `sessions_test.exs` has no equivalent for its GenServer's internal map; the
only recourse is polling with `eventually/2` after the fact, which is what produces
findings #1–#3. Consider adding a test-only "reset" call (or starting a second,
uniquely-named `Sessions` instance under `start_link/1` per test) the same way
`tickets_test.exs` gets a hard reset via ETS.

### 5. `redact_test.exs`'s grep guard only matches three hardcoded binding names
`test/live_ceci/redact_test.exs:98-108`

```elixir
File.read!(path) =~ ~r/Logger\.\w+\([^)]*[^.]\binspect\((reason|msg|other)\b/
```

Same category of guard as `agent_name_test.exs` (asked about last audit, and
reasonable there once anchored to real tokens). Here the anchoring is arguably too
narrow rather than too loose: it only catches `inspect(reason|msg|other)` written
*directly inside* a `Logger.\w+(...)` call. Two ways a future regression escapes it
silently:
  - a differently-named binding, e.g. `Logger.error("upstream: #{inspect(err)}")` or
    `inspect(cause)` — anything other than `reason`/`msg`/`other`.
  - building the string first and logging the variable, e.g.
    `text = "failed: #{inspect(reason)}"; Logger.error(text)` — `inspect(reason)`
    never appears inside the `Logger.\w+(...)` parens at all.
The guard is legitimate (it pins a real historical incident, same as
`agent_name_test.exs`) but should not be read as "nothing in lib/ leaks an upstream
reason" — only "nobody reintroduced this exact textual shape." Consider widening to
`inspect\(\w+\)` unconditionally inside any `Logger.\w+(...)` call (drop the specific
name list), which would also catch `err`/`cause`/`e` at the cost of also flagging
genuinely safe `inspect/1` calls that need an inline exclusion comment.

### 6. `Provider.Grok` 78.87% — the gap is real code, not just dead branches, but it is inherent to a hand-rolled WebSockex client
`lib/live_ceci/provider/grok.ex:38-79` (`open/1`'s WebSockex-backed branches)

`grok_test.exs` covers `open/1`'s pure-guard path (missing key, `grok_test.exs:425-428`)
and the failure-recovery half of the `send_json` error branch in isolation via
`close/1` (`grok_test.exs:317-337`), but never exercises `open/1`'s two real
`WebSockex.start_link/3` outcomes:
  - the `{:ok, ws}` branch followed by a successful `send_json` (line 59-62) — the
    actual happy path that returns `{:ok, ws}` from `open/1`.
  - the `{:error, reason}` branch from `WebSockex.start_link/3` itself (line 76-78) —
    connection refused / DNS failure / handshake rejection.
  - the branch where `start_link` succeeds but `send_json` fails and `open/1` then
    calls `close(ws)` before returning the error (line 64-73) — only `close/1`'s
    *effect* is tested standalone, not that `open/1` actually reaches it on this path.
  Also untested: `handle_frame(_frame, state)` catch-all (line 165), and
  `decode_args/1`'s final catch-all for a non-map/non-binary payload (line 326,
  reachable if the model sends `arguments` as e.g. a number or list).

These require a live (or fake-listening) TCP endpoint to hit for real, which is a
reasonable thing to leave to `priv/spike/` rather than unit tests — the moduledoc says
as much. Flagging because it's the most-uncovered module and the gap is concentrated
in exactly the two lines (72, 77) that hold the "already-billed, must close before
returning" contract described in the comment at line 65-74 — that is the highest-value
remaining gap, not a cosmetic one. A fake `:gen_tcp`/`WebSockex` stand-in (or extracting
the post-`start_link` logic into a function that takes an injected `start_fun`) would
let this be covered without a real socket.

## P3

### 7. Duplicated `eventually/2` poller now exists in three files
`test/live_ceci/application_test.exs:47-53`, `test/live_ceci/sessions_test.exs:140-146`,
`test/live_ceci/provider/grok_test.exs:273-279`

Each copy is individually compliant with "no `Process.sleep` outside a poller," but
there are now three near-identical private implementations instead of one shared
helper (e.g. in `test/support/`). Minor DRY issue, and it slightly muddies the "only
one poller in the whole suite" framing from the last audit — there are three
call-sites of the same *pattern*, each with its own sleep.

### 8. `sessions_test.exs`'s 1_000 ms `assert_receive` budgets under 40-way concurrency
`test/live_ceci/sessions_test.exs:47, 54, 126`

`holder/2`'s `assert_receive {:joined, result}, 1_000` runs inside 40 concurrent
`Task.async_stream` workers in the race test, each doing a real `GenServer.call` to
the same serialized `Sessions` process plus an `Agent.update/2` to a shared tracking
Agent. On a loaded CI runner (shared/throttled CPU) 1 second is a plausible, if
unlikely, place for the suite to flake on timeout rather than on the property under
test. Not urgent, but worth a wider margin (e.g. 5_000 ms, matching the
`Task.async_stream` timeout already used on the same line) since the whole point of
this test is to *add* contention.

## Answers to the specific questions

- **Q1 (ordering/leakage/isolation):** Unlinked `Agent` choice is correct; the cleanup
  built on it is not synchronous (P1 #1), and the file's assumption of a clean
  `Sessions` baseline is never verified (P1 #2/#3, P2 #4).
- **Q2 (exactly-5 assertion):** Logically sound given a clean baseline (GenServer
  serialization makes 5-of-40 exact, unlike the Registry's 3-of-40), but nothing
  guarantees the baseline is clean — see P1 #2/#3. It would still distinguish a
  reverted Registry design from the current one; it will also produce false failures
  unrelated to that regression under contamination.
- **Q3 (redact_test grep guard):** Legitimate regression guard, same category as
  `agent_name_test.exs`, but under-anchored (P2 #5) — three hardcoded variable names,
  and only matches when `inspect(...)` is textually inside the `Logger.\w+(...)` call.
- **Q4 (Grok 78.87%):** Uncovered code is `open/1`'s three `WebSockex.start_link`-backed
  branches (lines 59-78, including the "close before returning" contract) plus two
  catch-alls (`handle_frame/2` line 165, `decode_args/1` line 326). It matters — the
  close-before-returning contract is the highest-value gap — but is hard to cover
  without a fake transport (P2 #6).
- **Q5 (silent breakage in lib/):** Cross-referenced against the new tests — the
  clearest concrete case found is `Sessions`/`Socket.init` interaction (P1 #3): a
  regression that made `Sessions.join/1` leak permanently (e.g. forgetting
  `Process.monitor/1`) would eventually starve `sessions_test.exs`'s cap tests, but
  slowly and only visibly as flakiness, not a deterministic failure pointing at the
  actual bug.
- **Q6 (runtime / async:false serialization):** `sessions_test.exs` and
  `tickets_test.exs` are each internally serial in a way that's necessary (shared
  singleton), but neither needs to block the *other* — they touch disjoint global
  state (one GenServer map, one ETS table) and could both be `async: true` relative
  to each other if each used its own dedicated, uniquely-named instance instead of the
  app's singleton (see P2 #4). As written, all `async: false` files (`live_ceci_test`,
  `application_test`, `redact_test`, `sessions_test`, `socket_lifecycle_test`,
  `tickets_test`) run strictly serially in the sync phase after all `async: true`
  modules finish, which is more serialization than strictly required but is the
  correct trade-off given they share app-env/singleton state today.
