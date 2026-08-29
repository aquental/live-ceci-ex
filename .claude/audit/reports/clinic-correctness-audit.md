# Correctness/OTP/Performance Audit — commit 2f3d902

Scope: `lib/live_ceci/data.ex`, `lib/live_ceci/clinic.ex`, `lib/live_ceci/clock.ex`,
`lib/live_ceci/application.ex`, the changed parts of `lib/live_ceci/tools.ex`, and their
call sites. All claims below were checked by running code (`mix run -e` scripts against
the live app, VERIFIED BY EXECUTION) unless marked otherwise.

---

## P1 — `fechar_mes` loses a concurrent month-close (lost update, no error to either caller)

**Where:** `LiveCeci.Data.put_data/1` (`lib/live_ceci/data.ex:48-52`), called from
`LiveCeci.Tools.dispatch("fechar_mes", …)` (`lib/live_ceci/tools.ex:250-266`).

`fechar_mes` does read-modify-write with no atomicity: `Data.get_data()` (read) →
`Clinic.close_month/2` (pure transform) → `Data.put_data/1` (write), three separate ETS
operations with an arbitrary caller in between. Two browser sockets (each its own
process per the CONTEXT note) closing *different* months around the same time silently
clobber each other — the second write is not merged with the first, it replaces it.

**Verified by execution** (`scratchpad/verify2.exs`): two tasks each read the pre-write
snapshot, one closes "agosto", the other closes "julho"; the task holding the older read
wins the final write:

```
final months map after both closes (t1 delayed its write):
%{"agosto" => %{"status" => "closed", "year" => 2026},
  "julho" => %{"status" => "open", "year" => 2026}}
```

Both callers received a success result (`"mês fechado, dados encaminhados ao contador"`)
for their own month; one of those months quietly reverted to open with no error, no log,
and nothing in either spoken response that would let Ceci or the therapist know it
happened. Given `fechar_mes`'s own description ("Fecha o mês e encaminha os dados ao
contador"), this is exactly the operation this audit's stakes call out: a month can be
told to the model as closed-and-sent when it demonstrably isn't, and there is no
compensating check anywhere (no CAS, no version stamp, no re-read-after-write) that would
catch it.

**Consequence:** silent data loss on the one write path this app treats as consequential
("fechar_mes... só chamar depois que a pessoa confirmou em voz alta"). Not reachable from
a single browser tab in isolation, but reachable the moment two sessions exist
concurrently (which the app explicitly supports — `max_sessions` in `runtime.exs`).

---

## P2 — `resolve_month/2`'s two paths ("agosto" vs "2026-08") can silently disagree

**Where:** `LiveCeci.Clinic.resolve_month/2` (`lib/live_ceci/clinic.ex:63-90`), used by
both `preview_month/2` and `close_month/2`.

The name-path (`"agosto"`) trusts whatever `year` is stored in `months["agosto"]` and
never cross-checks it against `Clock.today()`. The ISO-path (`"2026-08"`) derives the
month name and then requires `months[name]["year"]` to *equal* the year in the phrase.
Because `months` is keyed only by bare Portuguese month name (12 possible keys, ever —
there is no room to represent two different Augusts), if the stored `year` for a month
entry is ever stale relative to the actual calendar year (an operator forgot to roll the
JSON forward, or a session runs across a year boundary with no code anywhere that updates
`months[name]["year"]`), the two phrasings a user would reasonably use for "this month"
stop agreeing — and one of them fails silently rather than loudly.

**Verified by execution** (`scratchpad/verify1.exs`), same `data`, only the month phrase
changed:

```elixir
data = %{
  "sessions" => [%{"patient_id"=>"p1","date"=>"2026-08-15","time"=>"09:00","status"=>"compareceu"}],
  "months"   => %{"agosto" => %{"status" => "open", "year" => 2025}}   # stale year
}
```

```
name-path ("agosto"):  %{status: "open", faltas: 0, mes: "agosto", recebimentos: 0, sessoes: 0}
iso-path  ("2026-08"): nil
```

The name-path doesn't return `nil` for the mismatch — it returns a *confident-looking,
wrong* answer: `sessoes: 0, recebimentos: 0`, built from `month_prefix(2025, 8)` =
`"2025-08"`, which matches nothing in a snapshot whose sessions are dated `2026-08-*`.
Ceci would speak that "agosto: 0 sessões, 0 faltas, 0 recebimentos" as if it were the
truth. The ISO-path for the same real-world intent instead reports "mês desconhecido" —
a different, also-wrong-but-at-least-honest answer.

**Consequence:** given the same intended month, "agosto" and "2026-08" are not
guaranteed to describe the same underlying (year, month) pair, and the failure mode for
the name path is a plausible-looking zero, not a nil the caller catches. This is a latent
bug specific to any deployment that survives a year rollover without an explicit process
to bump every entry in `months`, since no code path does that today. The fixture used in
tests happens to keep all years consistent (`2026` throughout), which is why the test
suite does not see it.

---

## P2 — `"este mês"` never resolves, despite being the example the tool schema tells the model to use

**Where:** tool declaration for `resumo_mensal` (`lib/live_ceci/tools.ex:106`): `"o mês
pedido, ex.: 'agosto' ou 'este mês'"`; resolved by `LiveCeci.Clinic.resolve_month/2`
(`lib/live_ceci/clinic.ex:63-90`); dispatch site `lib/live_ceci/tools.ex:201-217`.

`resolve_month/2` only understands two shapes: an exact key already present in the
`months` map (case/whitespace-insensitive), or an ISO `"YYYY-MM"` string. There is no
relative-date handling anywhere between the schema and `Clinic` — `Tools.dispatch` never
consults `LiveCeci.Clock.today()` when calling `preview_month/2` or `close_month/2` (only
`listar_sessoes_hoje` does). So if the model does what its own tool description invites
it to do — pass the literal string `"este mês"` — the tool always answers "mês
desconhecido — pergunte de novo", even though the current month is fully known and
present in `months`.

**Verified by execution** (`scratchpad/verify1.exs`):

```
este mes on empty data: nil
este mes on agosto-populated data (months has "agosto"=>year 2026): nil
```

Also confirmed by the existing test suite itself
(`test/live_ceci/clinic_test.exs:63`: `assert Clinic.preview_month(@data, "este mês") ==
nil` is asserted as the *expected* behavior), so this is a known gap, not an oversight in
the diff — but the tool's own description promises the opposite of what the code does.
A model that follows the description literally produces a dead-end turn every single
time a user says "e este mês, como estamos?", which is a very ordinary thing to ask an
assistant that just quoted last month's numbers.

**Consequence:** either the description overpromises (should not mention "este mês" as
an accepted value), or `resolve_month`/`dispatch` is missing the one line that would
special-case a small set of relative phrases via `Clock.today()`. As shipped, the two
disagree with each other.

---

## P3 — reduction ceiling only protects against argument size, not data size, and the test fixture can never catch that

**Where:** `test/live_ceci/tools_test.exs` `@budget_reductions 320`; the property test
"the cost does not grow with the size of what the model sends" scales the **argument**
(`String.duplicate("á", chars)`), never the **snapshot**. `LiveCeci.Data.get_data/0`
copies the whole snapshot out of ETS on every call, and `Clinic.patients/1`,
`sessions_on/2`, `preview_month/2`'s `month_rows/4` all do a full linear
`Enum.filter`/`Enum.map` over the entire `sessions`/`receipts`/`patients` list — the
lists never shrink or archive, so their size is exactly "how long this clinic has used
the app", not "what the model said this turn".

**Measured** (`scratchpad/bench.exs`, `scratchpad/bench2.exs`), starting from the
existing 3-session/1-receipt/2-patient fixture and scaling only `sessions`:

| sessions total | `resumo_mensal` reductions |
|---|---|
| 3 (shipped fixture) | 225 |
| 15 | 381 — **already over the 320 ceiling** |
| 30 | 577 |
| 300 (100x fixture) | 4605–6780 |

`get_data/0` copy cost at 100x fixture size (300 sessions/patients-ish rows): avg 28µs,
vs 0.15µs at 1x — linear, as expected of an ETS copy of a growing term.
`listar_pacientes` (2332–3321 reductions) and `listar_sessoes_hoje` (3064–5239
reductions) show the same shape at 100x.

Wall-clock stays comfortably under the 50ms `@budget_us` even at 100x (worst case ~54µs
measured), so this is **not** an active "the voice stalls" bug today — the absolute
numbers are still small. The problem is narrower and specific to what this commit's test
claims: the 320 ceiling was "measured after wiring Data (warm): … resumo_mensal and
listar_sessoes_hoje 283" — against the 3-session fixture only. Because the fixture is a
fixed literal in the test file, that measurement — and the ceiling calibrated from it —
can never be re-validated against a snapshot the size a real clinic will actually
accumulate (a two-person practice doing 4 sessions/day exceeds the 320-reduction ceiling
inside two work-weeks, per the table above). The test will pass forever regardless of
production snapshot size, so it stops meaning what its own comment says it means
("cost does not grow with the size of what the model sends" is true; the unstated other
half, size of what's stored, was not checked and does grow the cost).

**Consequence:** none today at current data volumes; the risk is that this ceiling reads
as a load-bearing guarantee about `dispatch/2`'s cost in production ("283… 320 is tight
against that") when it is only a guarantee about one axis (argument length) at one fixed,
tiny data size. If `months`/`sessions`/`receipts` are ever pruned/archived to keep this
true, that invariant lives nowhere the test suite checks.

---

## Checked, no finding

- **Supervision order** (`lib/live_ceci/application.ex:12-17`): `Data` starts before
  `Bandit`, matching the stated invariant and covered by
  `test/live_ceci/application_test.exs`. No bug — read source only.
- **`Application.fetch_env!(:live_ceci, :clinic_source)`** (`data.ex:94`): `config.exs`
  sets a default in all environments and neither `test.exs` nor `runtime.exs` ever unsets
  it, so this cannot currently raise in any configured environment. Read source only
  (`config/config.exs`, `config/test.exs`, `config/runtime.exs`).
- **ETS ownership / restart loss**: confirmed by execution
  (`scratchpad/verify3.exs`) that killing the `Data` process deletes the `:named_table`
  (owner death) and the restarted process reloads from `priv/data/clinic.json`, losing an
  in-memory `fechar_mes` close made since boot. This matches the module's own
  documentation ("A Data crash rebuilds from the file and loses in-memory closes") — not
  a new finding, but worth noting it compounds the P1 above: a close can be lost either
  by a concurrent write or by a crash, and in neither case does `fechar_mes`'s own
  response ("dados encaminhados ao contador") signal that the durability it implies isn't
  there.
- **`clock_hour/1`'s fourth/third clauses** (`lib/live_ceci/tools.ex:375-378`): both
  reachable. The two binary-pattern clauses only match exactly-5-byte binaries shaped
  `HH:00` or `HH:MM`; any other binary (wrong length, or a colon not in the third byte,
  e.g. `"manhã"`) falls to clause 3 (`is_binary`); any non-binary `time` value (missing
  key → `nil`) falls to clause 4. Verified by reading source and reasoning through the
  bit-pattern matches; no bug.
- **`month_prefix/2`** (`clinic.ex:131-132`): correct for months 1–12, single-digit
  padded. **`month_rows/4`** (`clinic.ex:120-129`) already guards a missing or non-binary
  `"date"` key with `_other -> false`, so such rows are silently excluded rather than
  crashing — defensible, and not an undercount for any row present in the shipped
  fixture. No bug.
- **`close_month/2` vs `preview_month/2` agreement**: both call the same
  `resolve_month/2` and therefore always agree with *each other* given the same `data`
  and `mes` — the disagreement is between two different *phrasings* of `mes` (see P2
  above), not between the two functions.

---

## Files referenced

- `/Users/aquental/projects/ai/google/live-ceci-ex/lib/live_ceci/data.ex`
- `/Users/aquental/projects/ai/google/live-ceci-ex/lib/live_ceci/clinic.ex`
- `/Users/aquental/projects/ai/google/live-ceci-ex/lib/live_ceci/clock.ex`
- `/Users/aquental/projects/ai/google/live-ceci-ex/lib/live_ceci/application.ex`
- `/Users/aquental/projects/ai/google/live-ceci-ex/lib/live_ceci/tools.ex`
- `/Users/aquental/projects/ai/google/live-ceci-ex/test/live_ceci/clinic_test.exs`
- `/Users/aquental/projects/ai/google/live-ceci-ex/test/live_ceci/data_test.exs`
- `/Users/aquental/projects/ai/google/live-ceci-ex/test/live_ceci/tools_test.exs`
- `/Users/aquental/projects/ai/google/live-ceci-ex/config/config.exs`,
  `config/test.exs`, `config/runtime.exs`
