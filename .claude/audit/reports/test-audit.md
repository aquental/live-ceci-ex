# Test-Health Audit — live-ceci-ex

Method: static read-through of the seven changed/added test files plus the
production modules they exercise (`LiveCeci.Tickets`, `LiveCeci.Limits`,
`LiveCeci.Sessions`, `LiveCeci.Router`, `LiveCeci.Provider.Gemini`). **No Bash
tool was available in this session, so the suite could not actually be run
with varying `--seed` values as requested** — the findings below are derived
from tracing the shared-state graph (ETS tables, GenServer singletons,
`Application.put_env`) across `async: true` and `async: false` modules, which
is where ExUnit's only real guarantee (`async: false` tests never run
concurrently with *other* `async: false` tests — it says nothing about
`async: true` tests) gets violated.

## P1 — order dependence / shared-global races

### 1. `TicketsTest.setup/0` unconditionally wipes the ETS table that `RouterTest` mints real tickets into, while the two run concurrently
- `test/live_ceci/tickets_test.exs:16-24` — every test's `setup` does
  `:ets.delete_all_objects(Tickets)` (and the counters table), with no
  filtering, no scoping to the tracked addresses.
- `test/live_ceci/router_test.exs:21-46,80-93` calls
  `LiveCeci.Tickets.issue/1` for nearly every test in the file, against the
  same named table (`LiveCeci.Tickets`, a process-global `:named_table`).
- `TicketsTest` is `async: false`; `RouterTest` is `async: true`. ExUnit only
  guarantees mutual exclusion between `async: false` modules — it does **not**
  guarantee `RouterTest` won't be scheduled at the same time as
  `TicketsTest`. When it is, `TicketsTest`'s setup can delete a ticket
  `RouterTest` just minted a few lines earlier in `ws_conn/2`/`ticket_conn/2`,
  between the `issue/1` call and the subsequent `call(conn)` that consumes
  it.
- What goes wrong: `router_test.exs:74-85` ("a ticket works exactly once")
  expects the *first* `call/1` to succeed and only the *second* to 403. If
  the table is wiped in between, the first call now sees `{:error, :invalid}`
  too — the assertion `refute call(...).status == 403` fails, intermittently,
  depending on scheduler timing/seed. Same exposure for every other
  `router_test.exs` case that relies on a ticket it just minted.

### 2. `TicketsTest`'s precise-count assertions assume it owns the whole table, but it doesn't when `RouterTest` runs at the same time
- `test/live_ceci/tickets_test.exs:104-118` ("the global bound evicts…") and
  `:120-137` ("derived, so the two cannot be raised out of step") both drop
  `max_tickets_per_address` to 10 and then assert an *exact* global count:
  `Tickets.outstanding() <= ceiling`, `Tickets.outstanding() == 20`.
- `issue/1` (`lib/live_ceci/tickets.ex:101`) triggers eviction off
  `:ets.info(@table, :size)` — the size of the **entire table**, not just the
  tracked addresses. Any ticket `RouterTest` mints concurrently (different,
  random addresses, `router_test.exs:22`) inflates that size, which (a) can
  trigger `evict_from_largest/0` earlier than the test's own math accounts
  for, and (b) `evict_from_largest/0` folds over the *whole* table
  (`lib/live_ceci/tickets.ex:128-136`), so it can just as easily evict one of
  `TicketsTest`'s own tracked tickets instead of a foreign one.
- Net effect: `assert Tickets.outstanding() == 20` (line 134) and
  `assert Enum.sum(held) == 20` (line 166, "eviction takes from whoever holds
  the most") are exact-equality assertions against a table another test file
  is concurrently writing into. These are flaky-by-construction, not just in
  theory — the shared resource and the write pattern are both confirmed in
  the code, only the interleaving is probabilistic.
- Fix: either make `TicketsTest` and `RouterTest` mutually exclusive (mark
  `RouterTest`'s ticket-dependent describes `async: false`, or give
  `LiveCeci.Tickets` a per-test sandbox/table), or have `RouterTest` stop
  routing through the real singleton for cases that don't test ticket
  behaviour.

### 3. `LimitsTest`'s first test mutates global `Application` env with no `on_exit`, so a failing assertion leaves the corrupted value in place for every test that runs after it
- `test/live_ceci/limits_test.exs:10-22`: loops `cap <- [1, 10, 150, 1_000]`,
  calling `Application.put_env(:live_ceci, :max_tickets_per_address, cap)`
  each iteration, and only calls `Application.delete_env/2` **after the loop
  exits**, as a plain function call — not registered via `on_exit`.
- If any iteration's `assert Limits.tickets_outstanding() == cap * 2` fails
  (e.g. a regression in the derivation this test exists to guard), the test
  process exits before reaching line 21, and `:max_tickets_per_address`
  is left at whatever `cap` last ran (as high as `1_000`). Because
  `LiveCeci.Tickets` reads this on every `issue/1` call
  (`lib/live_ceci/tickets.ex:113-114`), every subsequent test in the run —
  including all of `TicketsTest` and `RouterTest`'s per-address assumptions —
  now runs against a 1000/2000 cap instead of the intended 10 or 150,
  producing confusing secondary failures far from the actual regression.
- This is exactly the "cleanup that does not run on failure" pattern the
  audit was asked to hunt for, and it's the one file in this batch that
  doesn't use `on_exit` for a global mutation, even though its own comment
  ("async: false — every test here moves application env") shows the author
  was aware of the global-state hazard.

## P2 — assertions that would not fail if the code regressed

### 4. `GeminiTest` "the callbacks session_opts/1 wires" only proves the closures are *reachable*, not that `session_opts/1` is the thing that built them correctly end-to-end
- `test/live_ceci/provider/gemini_test.exs:204-238`: the setup calls
  `Subject.session_opts(owner: self(), model: "m", voice: "v")` and each test
  invokes one callback and asserts the resulting message. This is fine as far
  as it goes, and the comment (lines 205-208) is honest that it's checking a
  narrower claim than it looks. Flagging only because two of the five
  callbacks (`on_transcription`, `on_tool_call`) are asserted with a single
  example each and would not catch e.g. a swapped `:input`/`:output` tag
  being reintroduced for one direction while the other direction's own test
  (`"transcripts"` describe, line 95-102) already covers both — so the
  *duplication* here buys real coverage, this is a genuine (if narrow)
  strengthening, not a false-confidence test. No action needed beyond noting
  it for whoever reads the coverage number: this describe block is
  characterization, not specification, exactly as its own comment says.

### 5. `router_test.exs` X-Forwarded-For tests are order-independent from each other but silently depend on `TRUSTED_PROXIES` truly being `[]` between them
- `test/live_ceci/router_test.exs:238-249` ("ignored while empty") has no
  setup resetting `:trusted_proxies` itself; it relies on every *other* test
  in the file cleaning up after itself via `on_exit` (lines 253, 266, 281,
  296, 309). That's currently true, but there's no defensive assertion of the
  precondition (contrast with `sessions_test.exs:45-46`, which does assert
  its precondition). If a future edit to any of the proxy tests forgets its
  `on_exit`, this test would start passing or failing depending on run order
  with no error message pointing at the actual cause — the assertion
  (`conn.remote_ip == {10, 0, 0, 1}`) gives no hint that the real problem is
  stale global config.

## P3 — suggestions

- `tickets_test.exs:229-246` and `sessions_test.exs:206-239` both reach into
  `:sys.get_state/1` after `send/2` specifically to serialize against the
  GenServer's mailbox before `capture_log`. This is good, deliberate, and
  documented — no complaint, just noting it as the pattern to keep using
  rather than `Process.sleep`, since it's exactly right.
- Consider giving `LiveCeci.Tickets` (and `LiveCeci.Sessions`) a
  test-only reset/isolation hook (e.g., a `start_link` per test with a
  private table name) rather than relying on every caller across every test
  file to coordinate through a shared named table by convention. The current
  design works only as long as every test author remembers the "shared ETS
  table" constraint documented in comments — the two P1 races above are
  exactly what happens when that convention is not uniformly followed across
  files owned by different describe blocks.
