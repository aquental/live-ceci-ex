# Project health — live-ceci-ex — 2026-08-29

**Grade: B (81/100 weighted).** Up from C (57) on 2026-08-28.

Five parallel auditors — architecture, performance, security, tests, dependencies —
plus a consolidation pass. Every P1 and P2 was fixed during the audit rather than filed,
so this report describes the project **after** those changes; the raw findings are in
`../reports/`.

---

## A warning about this number

The scoring methodology in the plugin is built for Phoenix/Ecto applications. This
project is a plain Elixir OTP app: no Phoenix, no Ecto, no database, no LiveView, no
Mox. Applying the rubric literally scores the absence of things that were never
supposed to be here.

| Category | Points N/A | What was inapplicable |
|---|---:|---|
| Performance | 85 / 100 | N+1 (30), indexes (20), preloads (15), LiveView streams (10), `SELECT *` (10) |
| Security | 50 / 100 | sobelow critical (30), sobelow high (20) — sobelow is a Phoenix scanner |
| Test quality | 15 / 100 | `verify_on_exit!` — no Mox in this project |
| Architecture | 40 / 100 | Phoenix context boundaries (25), folder conventions (15) |

Each category below is scored on its **applicable** criteria and renormalised to 100.
That is stated per row. Do not compare this number to another project's; the
denominators differ. Comparing it to this project's own 2026-08-28 audit is fair,
because the same adaptation was made then.

---

## Scores

| Category | Score | Grade | 2026-08-28 | Basis |
|---|---:|:---:|---:|---|
| Architecture | 95 | A | 90 | 10 modules, **0 compile-time cycles**, 0 export edges, 13 runtime edges |
| Dependencies | 95 | A | 92 | 7 direct deps, all current, both audits clean, constraints now tight |
| Test quality | 88 | B | 80 | 136 tests, 81.9% coverage, no fixed sleeps, 8/11 files async |
| Performance | 80 | B | 20 | Both P1s fixed; one structural coupling survives, and it is not ours to fix |
| Security | 62 | D | 5 | Both P1s fixed; three P1s remain **deferred by explicit decision** |

```
overall = 95(.20) + 80(.25) + 62(.25) + 88(.15) + 95(.15) = 81.0
```

---

## What changed since yesterday

Eleven commits. The two F grades are gone.

**Security 5 → 62.** Bandit bound `0.0.0.0`, putting an unauthenticated WebSocket in
front of a metered API on the open LAN; it is loopback now, with `BIND_IP` as the
opt-in. A non-string tool argument crashed the live call, and — worse, because it was
silent — a list argument was flattened into a mangled patient name that Ceci then
confirmed out loud. A failed `session.update` leaked an open, billed xAI session that
nothing ever closed.

**Performance 20 → 80.** The downstream mailbox was unbounded; `send_timeout` is 5 s
instead of ThousandIsland's 30 s default, and voice frames are shed past 40 queued.
The Grok mic path no longer blocks the socket process.

**Tests 80 → 88.** 49 tests then, 136 now.

---

## Findings that remain open, and why

**Deferred by the user, deliberately.** The stated framing is that this is a POC for
testing voice functionality, with security hardening as a later phase.

- `/ws` has no `Origin` check. CSWSH against localhost is demonstrated, not theoretical.
- No auth ticket and no connection cap.
- The API key can reach the application log: `gemini_ex` puts it in the WebSocket URL
  and `socket.ex` logs `inspect(reason)` at several sites.

These are the whole of the 38-point security gap. Loopback binding contains all three
for local use, which is what makes D acceptable today and would not make it acceptable
the moment `BIND_IP` changes.

**Cannot be fixed from inside this repo.**

- The socket process serialises upstream and downstream for one listener. Fixed for
  Grok by casting; `gemini_ex`'s `send_realtime_input` is `handle_call` only
  (`session.ex:448`, `:461`) — there is no cast path, so that provider keeps the 1 s
  guard and the coupling.
- WebSockex keeps `extra_headers` in process state, so any crash report prints the xAI
  bearer token. It affects the **default** provider. Containing it means patching the
  dependency or fronting it with a proxy process.
- Every word spoken reaches the provider and is transcribed there. The
  "operational only, never clinical" boundary governs what Ceci writes down, not what
  she hears. `tools.ex` used to overclaim this and now says so explicitly.

**Accepted.**

- One xref cycle, `provider.ex` ↔ `provider/grok.ex`: `Provider.current/0` defaults to
  the Grok module at runtime, Grok declares `@behaviour Provider`. **Runtime only** —
  `mix xref --label compile` reports no cycles — so it costs nothing.
- Coverage 81.9%. The thin modules are `Provider.Gemini` (65.9%) and `Provider.Grok`
  (77.4%), both on connection paths that cannot be exercised without a live API.

---

## The finding no auditor made

Enforcing the schema's `maxLength` made the reductions budget in `tools_test.exs`
refuse the change. Investigating rather than raising the budget turned up this:

```
String.slice(value, 0, 200)   25_316 reductions   (200_000-char input)
binary_part(value, 0, 200)       301
```

`String.slice/3` walks the whole binary instead of stopping at the limit. The model
chooses that length, so this was unbounded work on the voice path, behind a tool call
that pauses her mid-sentence — steerable by anyone with a microphone. Bounded now by
taking a byte prefix first: 1219 reductions at 200 characters, 1643 at 2_000_000.

Two lessons worth keeping. A budget that exists to catch orders of magnitude will also
catch a subtler regression, but only if the response to a red test is to look rather
than to widen it. And the replacement test pins the **property** — ten thousand times
the input must not double the work — because a flat number is exactly what let the old
behaviour through.

---

## One report was corrected

`arch-review.md` claimed `{:websockex, "~> 0.4"}` cannot resolve the locked `0.5.1`,
reasoning that `~> 0.4` means `< 0.5.0`. It does not: a two-segment `~> MAJOR.MINOR`
means `< MAJOR+1.0.0`, and `Version.match?("0.5.1", "~> 0.4")` returns `true`.

The correction is annotated inline rather than deleted, with the check, because a report
that quietly loses a finding teaches nothing about how the finding was wrong. What
survived is `deps-audit.md`'s weaker and correct version: the constraint was loose, and
it is now `~> 0.5.1`.

Everything else was verified before being acted on — the tool-argument crash and the
two silent variants were reproduced, the orphaned session and the dead `get "/"` route
were read in the source, `send_timeout: 30_000` was read in the installed dependency,
and the absence of a `gemini_ex` cast path was read in `session.ex`.

---

## Action plan

**Now — nothing.** Every P1 and P2 is fixed or explicitly deferred.

**Before this leaves localhost**, in this order:

1. `Origin` check on the `/ws` upgrade. Cheapest of the three, closes the demonstrated
   CSWSH.
2. An auth ticket and a per-IP connection cap. `/ws` spends the API key's quota.
3. Stop `inspect(reason)` reaching the log with a key in it — a redacting formatter, or
   a proxy process holding the credential, which would also contain the WebSockex
   bearer token.

**Worth doing whenever, independently:**

- `session.reasoning.effort` on the xAI side is never set, so Grok runs on whatever the
  default is. It is the obvious suspect for the 1016 ms of generation the latency study
  measured, and it is one field.
- Manual turn detection measured **1186 ms against 3353 ms** with server VAD in probe 9
  of the Grok spike — n=1, direction real, magnitude unmeasured.
- Coverage on `Provider.Grok.open/1`'s success path, which is untested.
