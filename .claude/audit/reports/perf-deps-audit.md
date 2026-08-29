# Performance + dependency audit — live_ceci

Date: 2026-08-29 · Branch: main · Elixir 1.20.4 · macOS (darwin 25.6.0)

Everything below was measured with `:timer.tc` / `:erlang.statistics(:reductions)` via
`MIX_ENV=test mix run`, at the real table and holder sizes. Benchmarks are throwaway and
were not committed.

---

## Findings

### P2 — `LiveCeci.Tickets.issue/1` does three O(table) scans per mint, and `MAX_TICKETS_PER_ADDRESS` sets the table size

`/Users/aquental/projects/ai/google/live-ceci-ex/lib/live_ceci/tickets.ex:117` — `count_for/1`, `:ets.select_count` over every row, on **every** mint
`/Users/aquental/projects/ai/google/live-ceci-ex/lib/live_ceci/tickets.ex:197` — `sweep/0`, `:ets.select_delete` over every row, fires whenever `size > tickets_outstanding/2`
`/Users/aquental/projects/ai/google/live-ceci-ex/lib/live_ceci/tickets.ex:128` — `evict_from_largest/0`, `:ets.foldl` over every row, fires on every mint once the table is full

All three run in the connection process on `POST /ws-ticket`, so they queue behind
nothing — but they are all linear in `LiveCeci.Limits.tickets_outstanding/0`, which is
`MAX_TICKETS_PER_ADDRESS * 2`, and `config/runtime.exs:137` accepts `1..100_000`.

Component cost, 3 addresses sharing the table:

| table rows | `count_for` | `sweep` | `evict_from_largest` | `consume/2` |
|---|---|---|---|---|
| 50   | 2.3 µs   | 1.8 µs  | 6.9 µs   | 0.48 µs |
| 300  | 10.8 µs  | 8.1 µs  | 42.5 µs  | 0.44 µs |
| 3000 | 112.8 µs | 81.0 µs | 421.7 µs | 0.46 µs |

Whole-`issue/1` cost at a full table, driving the real module:

| `MAX_TICKETS_PER_ADDRESS` | table rows | `issue/1` |
|---|---|---|
| 150 (default) | 300     | **72.9 µs** |
| 1 000         | 2 000   | 446 µs |
| 10 000        | 20 000  | 4.0 ms |
| 100 000 (config max) | 200 000 | **45.3 ms** |

End to end through Bandit, `POST /ws-ticket`, default config:

```
empty table : 125.4 µs/request
full table  : 209.0 µs/request      (GET /healthz baseline: 149.5 µs)
```

**At the default this is not a problem** — 73 µs, and only during a flood. Concurrency is
also fine: 1/4/16/64 concurrent minters against a full table gave 74.6 / 36.5 / 34.1 /
36.7 µs per mint wall-clock, i.e. it parallelises and does not collapse on the table lock
despite `read_concurrency: true` with no `write_concurrency`.

Why it is still worth recording: `tickets.ex:24` and `limits.ex:41-47` both explicitly
point at raising `MAX_TICKETS_PER_ADDRESS` for a NAT/reverse-proxy deployment where "per
address" is everyone — which is exactly the deployment that has to raise it, and the one
where 45 ms of CPU per ticket request becomes the DoS the bound was written to prevent.
The measured scaling is clean linear, so the cliff is reachable by config alone with no
code change.

Cheapest fix, if it is ever raised: keep a per-address count in the existing `@counters`
table (`tickets.ex:65`) — `:ets.update_counter` on insert, decrement on delete — which
makes `count_for/1` O(1) and gives `evict_from_largest/0` its max without the fold. The
sweep can stay; it is already the smallest of the three.

### P3 — two transitive deps held behind latest by `gemini_ex`

`/Users/aquental/projects/ai/google/live-ceci-ex/mix.exs:44` (`{:gemini_ex, "~> 0.17.0"}`)

```
joken   2.6.2 -> 2.7.0   Update not possible
req     0.6.3 -> 0.7.4   Update not possible
```

No advisory on either — `mix deps.audit` and `mix hex.audit` are both clean. Both are
pulled in for `gemini_ex`'s REST/Vertex-JWT path, which this app never uses (it uses the
Live WebSocket path, and `MODEL` defaults to Grok). Informational: nothing to do until
`gemini_ex` relaxes its requirement.

---

## Dependency half — clean

```
$ mix deps.audit    No vulnerabilities found.
$ mix hex.audit     No retired or security advisory packages found
$ mix hex.outdated  all 8 direct deps Up-to-date
$ mix deps.unlock --check-unused   (no output — nothing stale in mix.lock)
```

No unused deps. All eight direct deps have a live call site:

| dep | used at |
|---|---|
| `bandit` | `lib/live_ceci/application.ex:18` |
| `plug` | `lib/live_ceci/router.ex:17` (`use Plug.Router`) |
| `websockex` | `lib/live_ceci/provider/grok.ex:39` (`use WebSockex`) |
| `websock_adapter` | `lib/live_ceci/router.ex` (`WebSockAdapter.upgrade/4`) |
| `websock` | `lib/live_ceci/socket.ex:48` (`@behaviour WebSock`) |
| `gemini_ex` | `lib/live_ceci/provider/gemini.ex`, Gemini carrier |
| `jason` | router, socket, grok, gemini |
| `mix_audit` | dev/test tooling |

---

## Verified non-findings (measured, so this does not get re-audited)

Everything the brief flagged as new this session was measured and is free.

**`lib/live_ceci/limits.ex` — the six `Application.get_env` reads**

```
Application.get_env(:max_session_bytes)  0.119 µs
Limits.session_byte_budget/0             0.113 µs
LiveCeci.config/0 (9 reads + map build)  0.502 µs, 74 reductions
```

`session_byte_budget/0` is read per mic frame at `socket.ex:236`. At 10 frames/s that is
1.1 µs per second of audio. The whole of `spent/2` (`socket.ex:233` — `byte_size` +
the `Limits` read + the map update) measures **0.039 µs/frame**. Not on the latency budget.

**`lib/live_ceci/router.ex` — `restore_client_address` and per-request `connect_src`**

`router.ex:87` / `router.ex:102` / `router.ex:139` (re-measured against the current
`connect_src/1`, which now also calls `bracket_ipv6/1`):

```
restore_client_address, TRUSTED_PROXIES empty (the default)     0.489 µs
Regex.match?(@host_chars, conn.host)                            0.338 µs
connect_src/1 whole (regex + bracket_ipv6 + 4 interp + concat)  0.644 µs (host "localhost")
                                                          "     0.672 µs (host "::1")
```

~1.13 µs combined, against a measured **125–251 µs** per HTTP request through Bandit
(`GET /main.js` via `Plug.Static` is 251 µs). Under 1% of the cheapest request, on a
path that runs a handful of times per page load and never during a call.

**`lib/live_ceci/tickets.ex:171-176` — `consume/2` as a match spec**

0.44–0.46 µs at 50, 300 and 3000 rows, and 0.45 µs on a hit at 300 rows. Flat across a
60x table-size change, which confirms the comment's claim that binding the ticket
literally keeps this a hash lookup on the `:set` rather than a scan. This is the one
`:ets.select_delete` in the module that is genuinely O(1).

**`lib/live_ceci/socket.ex:236` — the per-frame byte counter**

Covered above: 0.039 µs/frame including the config read.

**`Process.flag(:sensitive, true)` on the Grok WebSockex process (`grok.ex:185`)**

Worth checking because `Grok.send_audio/2`'s deliberate bound reads that process's queue
length, and `:sensitive` withholds process internals:

```
sensitive proc, Process.info(:message_queue_len) -> {:message_queue_len, 100}   (real)
sensitive proc, Process.info(:messages)          -> {:messages, []}             (hidden)
```

`:message_queue_len` survives, so the drop bound at `grok.ex:143` is live, not dead. And
`:sensitive` costs nothing: 100k frame round trips of a 3200-byte binary measured
0.466–0.476 µs plain vs 0.466–0.513 µs sensitive — inside noise across two interleaved
reps. `Process.info(other, :message_queue_len)` is 0.062 µs.

**`Logger.debug` with an eager-looking interpolation (`socket.ex` fall-through, `grok.ex:200`)**

`Redact.inspect/1` costs 6.009 µs standalone. Behind `Logger.debug` at `level: :info`
(dev/prod) it costs **0.074 µs** — the macro defers it. No leak onto the socket process.

**`LiveCeci.Sessions` — the singleton every upgrade queues behind**

`count_for/2` (`sessions.ex:182`) is an `Enum.count` over the holders map, run on both
`:join` and `:available?`:

```
MAX_SESSIONS=8   (default),   7 holders:   1.09 µs/call
MAX_SESSIONS=100,            99 holders:   3.24 µs/call
MAX_SESSIONS=1000 (max),    999 holders:  26.77 µs/call
```

At the default the router's deliberate two calls per upgrade cost ~2.2 µs serialised,
matching the ~12 µs the comment above the `available?/1` branch in `get "/ws"` claims (that figure includes the
`GenServer.call` round trips). Even at the config maximum, 27 µs supports ~37k calls/s
through the singleton, against 1000 sessions that each cost an upstream connection. Not
a bottleneck at any reachable setting.

**Unbounded growth** — nothing found. Ticket table is pinned at `tickets_outstanding` by
the evict-on-full path; the `@counters` table holds one key; `Sessions.holders` is capped
by `max_total`; socket state is `{session, provider, bytes}` with `bytes` capped by the
budget; both carrier processes hold `{session, dropped}`. `Persona`/`Tools` are
compile-time module attributes (`persona.ex:21` with `@external_resource`), so no
per-connection disk or rebuild.

---

## What was not examined

No SQL, no Ecto, no database — correctly out of scope per the brief. The known-and-
deliberate items (removed logging in `Tickets.issue/1` and `Sessions.handle_call/3`,
bounded queues with frame dropping, the router's two `Sessions` calls per upgrade) were
re-measured only where a new measurement was needed to rule something out, and are not
reported as findings.
