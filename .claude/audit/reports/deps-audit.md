# Dependency Audit — live-dj-ex

Date: 2026-08-28 · Elixir 1.20.3 / OTP 29 · 5 direct deps, 22 total in lock

## Clean areas (one line each)

- **Freshness:** all 5 direct deps are at the newest published stable version (`mix hex.outdated`: 5/5 Up-to-date). Nothing is behind; no constraint edit is needed for any upgrade.
- **Retirement/advisories:** no direct or transitive dep is retired. (`mix hex.audit` clean; hex.pm retirement maps checked per-package — bandit 1.10.0 and plug 1.20.0/1.20.1/1.13.x are retired upstream, but the lock sits on bandit 1.12.5 and plug 1.20.3, clear of all of them.)
- **Unused deps:** none. All 5 are directly referenced in `lib/`; `mix deps.unlock --check-unused` is clean.
- **Maintenance:** bandit, plug, jason, req, telemetry, jose all released within the last ~4 months by active maintainers.

Everything below is an actual finding.

---

## HIGH — `{:gemini_ex, "~> 0.17"}` is under-constrained for a 0.x core dependency

`~> 0.17` resolves to `>= 0.17.0 and < 1.0.0`. It is **not** `< 0.18.0`. Verified:

```
~> 0.17 vs 0.18.0 => true
~> 0.17 vs 0.99.0 => true
~> 0.17.0 vs 0.18.0 => false
```

Why this matters here specifically:

- gemini_ex is the load-bearing dep. `lib/live_dj/socket.ex`, `lib/live_dj/minimal.ex` and `lib/live_dj/gotcha.ex` pattern-match `%Gemini.Types.Live.ServerMessage{server_content: %Gemini.Types.Live.ServerContent{}}` and `%ToolCall{}` **directly in function heads**, and pass the five-callback keyword contract (`on_message`/`on_transcription`/`on_error`/`on_close`/`on_tool_call`) to `Gemini.Live.Session.start_link/1`. A renamed struct field is a `FunctionClauseError` at runtime, not a compile error.
- Release cadence is fast and the churn is in exactly the wrong place. From hex.pm: 0.11.0 (2026-03-05) → 0.17.0 (2026-08-21) — **7 minor releases in ~5.5 months**, roughly one every 3 weeks.
- The project's own changelog proves 0.x minors carry breaking internals: **0.16.0 "Replaced the Gun/Cowlib Live WebSocket stack with WebSockex"** — a full transport rewrite of the Live path this app depends on, shipped as a minor.
- Low adoption (13.2k all-time downloads, ~300/week) and a single-maintainer repo (`nshkrdotcom/gemini_ex`) mean breakage will not be caught by community pressure before you hit it.

`mix.lock` currently protects you. But `mix deps.update gemini_ex`, a fresh clone with a stale/absent lock, or any transitive re-resolution silently jumps up to 0.99.

**Fix** — pin to the minor in `mix.exs:34`:

```diff
-      {:gemini_ex, "~> 0.17"},
+      # 0.x: minors carry breaking changes (0.16.0 rewrote the Live WebSocket
+      # transport). socket.ex pattern-matches Gemini.Types.Live.* struct shapes,
+      # so a minor bump is a runtime FunctionClauseError, not a compile error.
+      {:gemini_ex, "~> 0.17.0"},
```

`~> 0.17.0` == `>= 0.17.0 and < 0.18.0`. Upgrades then become a deliberate edit + changelog read, which is the correct ceremony for this dep.

---

## MEDIUM — no CVE scanning in the project

`mix hex.audit` only checks **Hex retirement flags** — a maintainer opt-in signal. It does not consult any CVE/advisory database. `mix deps.audit` is unavailable because `mix_audit` is not a dependency, so this repo currently has **zero** coverage against published Elixir security advisories, including transitively (jose, mint, plug_crypto, joken all sit in the graph and all have advisory history in the ecosystem).

This is cheap to close and is the one piece of tooling worth adding unconditionally.

**Fix** — `mix.exs`:

```diff
       {:gemini_ex, "~> 0.17.0"},
-      {:jason, "~> 1.4"}
+      {:jason, "~> 1.4"},
+
+      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
     ]
```

```
mix deps.get && mix deps.audit
```

---

## LOW — `{:websock_adapter, "~> 0.5"}` already drifted a minor; declaration no longer matches reality

**Confirmed: the reading is correct.** `~> 0.5` == `>= 0.5.0 and < 1.0.0`, verified:

```
~> 0.5 vs 0.6.0 => true    ~> 0.5 vs 0.9.9 => true    ~> 0.5 vs 1.0.0 => false
```

So 0.6.0 in the lock is permitted, and this is a *real* silent 0.x minor crossing — the 0.5 line ran from 2023-06 to 2025-11 (0.5.9) and 0.6.0 landed 2026-04-15. `mix.exs` says "0.5" while the app has only ever been built and tested against 0.6.0.

**Is it a real risk in this case? Assessed: no actual breakage, but only by luck.** The entire 0.6.0 changelog is one entry:

> Change default `max_frame_size` to be 10MB (was `:infinity`)

That is a genuine behavior break for a binary-PCM app — a default frame cap appearing where there was none would truncate audio uploads. This project is immune purely because `lib/live_dj/router.ex:27` passes the option explicitly:

```elixir
|> WebSockAdapter.upgrade(handler, [], timeout: 60_000, max_frame_size: 1_000_000)
```

The risk that remains is forward-looking: `~> 0.5` still authorizes 0.7, 0.8, 0.9 sight-unseen. websock_adapter is a Phoenix-team package on a slow, conservative cadence (7 releases in 3 years), so the probability is low — hence LOW, not HIGH. But the constraint should state what is actually supported.

**Fix — recommended: tighten to `~> 0.6`** (`mix.exs:31`):

```diff
-      {:websock_adapter, "~> 0.5"},
+      {:websock_adapter, "~> 0.6"},
```

`~> 0.6` (`>= 0.6.0, < 1.0.0`) is the right call over `~> 0.6.0` here — it is a thin, stable adapter with a trivial public surface (one `upgrade/4` call), not a deep API dependency like gemini_ex. The value is documentary: it stops mix.exs from claiming support for a 0.5 line that is no longer exercised, and forces a re-read at the next minor. Use `~> 0.6.0` instead only if you want every websock_adapter minor to be a deliberate decision.

---

## LOW — `.formatter.exs` does not import plug's exported formatter config

Verified by inspecting each dep's `.formatter.exs`: **plug exports** `locals_without_parens` (`plug: 1, plug: 2, forward: 2..4, match: 2..3, get/post/put/patch/delete: 2..3`). bandit, websock_adapter, websock, jason and gemini_ex export nothing (bandit/websock_adapter/websock/jason ship no `.formatter.exs` at all; altar/req ship `inputs`-only files with no `export:` key). typed_struct exports `field: 2, field: 3` but is transitive-only and not used in this repo's code.

`lib/live_dj/router.ex` uses `use Plug.Router` and writes `plug(Plug.Static, ...)` with parens — correct output today, but only because the formatter has no idea `plug` is a macro DSL. Importing plug's export gives the idiomatic paren-free style and makes any future `get "/health", ...` route format correctly.

**Fix** — `.formatter.exs`:

```diff
 [
+  import_deps: [:plug],
   inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
 ]
```

Then `mix format` and commit the reflow in one isolated commit.

---

## LOW — `req` held two minors back by a gemini_ex pin (transitive, no action available)

`mix hex.outdated --all` shows the single non-current package in the whole graph:

```
req    0.6.3    0.7.4    Update not possible
```

Blocked by gemini_ex's own `{:req, "~> 0.6.2"}`. Not fixable from this repo — an override would be worse than the problem. req 0.6.3 shipped 2026-07-16 (6 weeks old) and carries no advisory, so this is informational. It is however a second data point on the same theme as the HIGH finding: **gemini_ex pins all seven of its deps to patch-level `~> x.y.z` ranges** (`jason ~> 1.4.4`, `joken ~> 2.6.2`, `req ~> 0.6.2`, `telemetry ~> 1.4.2`, `typed_struct ~> 0.3.0`, `websockex ~> 0.5.1`, `altar ~> 0.2.0`). Expect gemini_ex to be the binding constraint on this project's whole dependency graph, and expect version-conflict friction if you ever add a dep that wants a newer req or jason.

Track only: `typed_struct` (transitive via gemini_ex) last released **2022-02-15**, 4.5 years stale. Widely used and effectively feature-complete, so not a defect — just note it is unmaintained if it ever surfaces in a stack trace.

---

## Dev/test tooling gap — recommendation kept proportionate

8 modules in `lib/`, 3 test files, a demo repo. Do **not** install the full production gauntlet. Ranked:

| Tool | Verdict | Rationale |
|---|---|---|
| `mix_audit` | **Add** (see MEDIUM above) | Closes a real zero-coverage gap. Zero maintenance cost, runs in seconds. |
| `credo` | **Optional** | This codebase is already idiomatic and heavily commented. Credo would mostly generate noise on a repo whose value is pedagogical. Add only if you want the enforcement in CI. |
| `dialyxir` | **Skip for now** — but the one place it would pay off is here | The whole risk surface of this app is untyped struct pattern-matching against a churning 0.x library. Dialyzer would catch a `Gemini.Types.Live.*` shape change at analysis time rather than at runtime. The cost is a multi-minute PLT build on a repo with no CI. Revisit if you loosen the gemini_ex pin. |
| `excoveralls` | **Skip** | 3 test files. Coverage percentage carries no information at this size. |

There is also **no CI** (`.github/workflows` does not exist). If you add only one automated check, make it `mix deps.audit` — it is the only finding here that can change without you touching the repo.

---

## Verification commands run

```
mix hex.outdated              # 5/5 direct deps Up-to-date
mix hex.outdated --all        # 21/22 current; req blocked by gemini_ex
mix hex.audit                 # no retired/advisory packages
mix deps.unlock --check-unused# clean
elixir -e 'Version.match?(...)'  # constraint semantics confirmed
curl hex.pm/api/packages/*    # release dates + retirement maps for all deps
grep -rn <each dep> lib/ config/ test/  # usage confirmed for all 5
cat deps/*/.formatter.exs     # formatter exports enumerated
```
