# Test-health audit — commit 2f3d902

Scope: `test/live_ceci/clinic_test.exs`, `test/live_ceci/data_test.exs`, changed parts of
`tools_test.exs`, `persona_test.exs`, `application_test.exs`,
`provider/grok_test.exs`, `provider/gemini_test.exs`.

**Caveat**: this environment has no shell/Bash access, only Read/Grep/Glob. I could not
execute `mix test --seed <n>` as requested; findings below are from static read-through of
the test files against `lib/live_ceci/{data,clinic,tools,clock}.ex`. Nothing here depends
on a claim about runtime behavior I couldn't verify statically — flag anything you can
run and I can't.

## P1

### 1. `tools_test.exs:191-283` — the 320-reduction ceiling is only tight for two of seven tools
The budget is one shared constant checked against every entry in `@cases` (line 280:
`assert burned < @budget_reductions`). The comment's own numbers (lines 230-234) show why
that's a problem:

| tool | measured | headroom to 320 |
|---|---|---|
| agendar_sessao / confirmar_presenca / emitir_recibo (stubs) | 66-75 | 245-254 |
| listar_pacientes | 78 | 242 |
| fechar_mes | 145 | 175 |
| resumo_mensal / listar_sessoes_hoje | 283 | 37 |

The comment argues a `File.read!` (~40 reductions) would push 283 → 323 and trip the
ceiling — true, but only for those two. A `File.read!`, or something considerably more
expensive, added to `agendar_sessao`, `confirmar_presenca`, `emitir_recibo`,
`listar_pacientes`, or `fechar_mes` has 175-254 reductions of slack to hide in and this
test would still pass. That's 5 of 7 dispatch clauses — including the two the docstring
names as the likely first offenders ("agendar" and "emitir recibo... SOUND like they
should hit a database") — where this regression test does not catch the regression it
exists to catch. A `GenServer.call` on those same paths would likely also clear the
50 ms wall-clock budget (line 205) if the callee replies fast, so neither half catches it.

Fix: per-tool budgets (or a percentage-over-baseline budget), not one ceiling shared
across a 4x range of legitimate costs.

## P2

### 2. `clinic_test.exs` — malformed rows are never exercised
`Clinic.month_rows/4` (`lib/live_ceci/clinic.ex:120-129`) has a defensive clause for
sessions/receipts that aren't a map with a binary `"date"` (`_other -> false`). No test
in `clinic_test.exs` includes a row missing `"date"`, a non-string `"date"`, or a
non-map entry in `"sessions"`/`"receipts"`. If that clause were changed to raise, or to
silently miscount, no test would fail. The task explicitly asked for this case ("a
malformed row") and it isn't covered — `preview_month/2` and `close_month/2` are both
exercised only against uniformly well-shaped fixture data.

### 3. `clinic_test.exs:74-77` — `close_month/2` via `"2026-08"` only tests the success path
The ISO-spelling branch of `close_month/2` is tested once, for the happy path. The
already-closed and unknown-month branches (lines 65-72) are only exercised through the
name spelling ("agosto"/"julho"/"setembro"), never through `"2026-MM"`. `resolve_month/2`
has a separate code path for ISO input (`iso_year_month/1` + year cross-check at
`clinic.ex:81-84`), so a bug specific to that branch (e.g. the `%{"year" => ^year}` guard)
wouldn't necessarily be caught by the name-spelling tests of the same error cases.

## P3

### 4. `tools_test.exs:264-283` ("no tool does real work") — pre-warm call has a side effect the loop then masks
The pre-warm loop at line 266 (`for {name, args} <- @cases, do: Tools.dispatch(name, args)`)
runs before `Data.reset(@clinic)` is called inside the timing loop, so it silently closes
"agosto" once (via `fechar_mes`) against the setup's freshly-open snapshot. It's harmless
today because every timed iteration resets state first (line 272), but it's a footgun for
whoever adds a case to `@cases` that isn't idempotent and doesn't realize the warm-up call
runs unguarded — worth a one-line comment or moving the reset before the warm-up loop.

### 5. `data_test.exs:43-52` — cleanup relies on ordering within `setup`/`on_exit`, not stated as such
`original = Data.get_data()` is captured in `setup`, then the test calls
`:ets.delete_all_objects(Data)` directly (not through `Data.reset/1`). This is fine as
written (on_exit puts `original` back via `Data.reset/1` regardless of pass/fail), but
it's the only test in the suite that mutates the table by a route other than
`put_data/reset`, so a future refactor of `reset/1` (e.g. adding a second ETS key) would
silently stop being exercised by this particular test's cleanup path. Not a bug, just
worth a comment given how deliberate the rest of the file is about `Data`'s cleanup
discipline.

## Not found (checked and clear)
- No test in scope touches `Application.put_env(:live_ceci, :today, ...)` — the frozen
  clock (`config/test.exs:14`, `~D[2026-08-15]`) is never overridden and never restored
  because nothing changes it. `tools_test.exs:83-87`'s "for Clock.today" assertion is
  correctly pinned to the frozen date, not the real one.
- `grok_test.exs` / `gemini_test.exs` are `async: true` and both call
  `Tools.dispatch/2`, but only through stub tools (`emitir_recibo`, `agendar_sessao`,
  `confirmar_presenca`) or `resumo_mensal` against the empty `clinic_source` from
  `config/test.exs:13` — none of them call `Data.reset/1` or `fechar_mes`, so there's no
  write-write or write-read race between these two async files or with the async:false
  `Data`/`Tools` test files.
