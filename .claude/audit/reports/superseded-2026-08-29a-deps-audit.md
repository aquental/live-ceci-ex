# Dependency Re-Audit — 2026-08-29

Follow-up to the 95/A audit. `mix hex.audit` / `mix deps.audit` re-confirmed clean
(no retired/advisory packages, no vulnerabilities); 0 xref cycles. Previously-fixed
items (mix.exs constraints, websock direct declaration, `.tool-versions`, CI file,
gemini_ex internal-call regression test) verified present and correct — not re-listed
below except where a new angle surfaced.

## P1

None.

## P2

1. **`.formatter.exs` doesn't cover `priv/`, so CI's format gate never checks
   `priv/spike/latency_bench.exs`.**
   `/Users/aquental/projects/ai/google/live-ceci-ex/.formatter.exs:3` — `inputs` is
   `["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]`. There is no `priv/**`
   glob. `mix format --check-formatted` in CI
   (`.github/workflows/ci.yml`) silently passes regardless of that file's formatting —
   this is exactly the "let a broken commit through" gap the audit asked about, scoped
   to the one `.exs` file that lives outside `lib`/`test`. Add `"priv/**/*.exs"` (or
   `"priv/spike/**/*.exs"`) to `inputs`.

2. **`mix.exs`'s `elixir: "~> 1.17"` no longer reflects what's actually built/tested.**
   `/Users/aquental/projects/ai/google/live-ceci-ex/mix.exs:8` vs `.tool-versions:2`
   (`elixir 1.20.4-otp-29`). `~> 1.17` accepts anything from 1.17.0 up to (not
   including) 2.0 — a contributor on a stray local 1.17–1.19 toolchain passes the
   `mix.exs` floor check and compiles, while CI's `version-type: strict` only ever
   builds against exactly 1.20.4. That's a silent floor/CI mismatch, not a hardening
   nicety: a contributor could ship code that behaves differently under 1.17 (a
   removed deprecation warning, a stdlib difference) and have no local signal before
   push. Tighten to `"~> 1.20"` to match what CI actually exercises — the file's own
   comment already admits this ("says nothing about the ceiling").

3. **CI runs `mix deps.audit` but not `mix hex.audit`, even though the two check
   different signals.** `.github/workflows/ci.yml` — the comment above the
   `deps.audit` step explains `hex.audit` "only reads maintainer retirement flags,"
   which is true but is an argument for running *both*, not for dropping the cheaper
   one. A maintainer retiring a package (e.g. citing an unpatched flaw) can predate a
   formal advisory entry landing in the DB `deps.audit` reads. One extra line
   (`mix hex.audit`) costs nothing in a job that already runs `deps.get`.

4. **CI still doesn't gate on `mix xref` (confirmed, as flagged in the audit brief).**
   The graph is 13 modules / 0 cycles today, cheap to keep true by construction. With
   no step enforcing it, a future PR can introduce a cycle or an unreachable/dead
   call and nothing in CI notices — `mix compile --warnings-as-errors` catches
   statically-resolvable undefined calls but not xref's broader cross-module checks
   (`mix xref graph --format cycles`, `mix xref unreachable`). Worth adding while the
   graph is small enough that a regression is trivial to unwind.

## P3

5. **`actions/cache` key never changes when `.tool-versions` bumps.**
   `.github/workflows/ci.yml` — `key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}`
   with `restore-keys: ${{ runner.os }}-mix-`. Bumping the OTP/Elixir pin without
   touching `mix.lock` restores a `deps`/`_build` tree built under the old toolchain;
   Mix's own manifest-version check forces a recompile on a real Elixir-version
   mismatch, so this is unlikely to corrupt a build today, but it's dead weight in the
   cache and would start mattering the moment anything version-sensitive is cached
   here (a Dialyzer PLT, a NIF). Folding `hashFiles('.tool-versions')` into the key
   costs one token and removes the question.

6. **No `permissions:` block on the workflow.** `.github/workflows/ci.yml` — defaults
   to the repo's broadest default `GITHUB_TOKEN` scope for a job that only needs to
   read the checkout and never writes anything back. Add `permissions: contents: read`
   at the workflow or job level.

7. **`{:websock, "~> 0.5"}` is looser than the app's own stated rationale for
   depending on it directly.** `mix.exs:22` — the comment explains websock is declared
   directly *because* `LiveCeci.Socket` implements `@behaviour WebSock`, i.e. the same
   "a behaviour you implement is a dependency you have" argument the file makes for
   pinning `gemini_ex` and `websockex` tighter. `~> 0.5` and `~> 0.5.3` (the version
   actually locked) have the same upper bound, so this changes nothing today, but for
   consistency with the file's own reasoning it should read `~> 0.5.3`.

8. **`erlef/setup-beam@v1` floats on a major-version tag.** `.github/workflows/ci.yml:21`
   — acceptable and idiomatic in the Elixir ecosystem, but note for the record since
   `actions/checkout` and `actions/cache` are first-party GitHub actions and this one
   isn't; a stricter supply-chain posture would pin to a release tag or SHA.

9. **No scheduled (cron) re-run of the advisory checks.** Both `mix deps.audit` and
   (recommended above) `mix hex.audit` only run on push/PR. A newly-disclosed CVE
   against an already-merged dependency version won't surface until the next commit
   touches this repo. A weekly `schedule:` trigger would close that gap; low priority
   given the dependency count (8 direct, 19 total).

## Verified, no new finding

- **`mix hex.outdated`**: every direct dependency (`bandit` 1.12.5, `gemini_ex` 0.17.0,
  `jason` 1.4.5, `plug` 1.20.3, `websock` 0.5.3, `websock_adapter` 0.6.0, `websockex`
  0.5.1, `mix_audit` 2.1.5) is already at latest. Nothing moved since the last audit.
- **`gemini_ex`**: 0.17.0 (2026-08-21) remains latest on Hex; no `[Unreleased]` entries
  in its `CHANGELOG.md`, no commits past the 0.17.0 tag on GitHub. The internal
  `{:send_realtime_input, opts}` `handle_call` clause the regression test guards is
  still present at `deps/gemini_ex/lib/gemini/live/session.ex:448`. Risk profile
  (single maintainer, internal message + struct pattern-matching) is unchanged, not
  worsened — CHANGELOG shows 0.16.0 already swapped the Live transport once (Gun/Cowlib
  → WebSockex), which is the precedent the app's own pinning comment is guarding
  against.
- **Dependency usage audit**: every declared dep has a genuine (non-comment) call site
  — `bandit` (`application.ex`), `plug` (`router.ex`), `websockex` (`provider/grok.ex`,
  `priv/spike/latency_bench.exs`), `websock_adapter` (`router.ex`), `websock`
  (`socket.ex`, `@behaviour WebSock`), `gemini_ex` (`live_session.ex`,
  `provider/gemini.ex` — real `alias Gemini.Live.*` / `Gemini.Types.Live.*` usage, not
  just doc mentions), `jason` (`socket.ex`, `router.ex`, `provider/grok.ex`),
  `mix_audit` (dev/test tool, invoked as a Mix task, no code reference expected).
  Nothing declared is unused; nothing used is undeclared **except** the item below.
- **`:crypto` (used in `lib/live_ceci/tickets.ex:67`, `:crypto.strong_rand_bytes/1`) is
  not in `extra_applications`** (`mix.exs:16` lists only `:logger`). This is not
  currently broken — `:crypto` is guaranteed to already be started transitively
  (gemini_ex → req → finch → mint → `:ssl`, which itself depends on `:crypto`), so a
  release boots it regardless. It is, however, an *implicit* invariant resting on a
  transport three dependencies away that this project's own comments describe as
  already having been swapped once (Gun/Cowlib → WebSockex in gemini_ex 0.16.0). If
  that HTTP stack is ever removed or swapped for something that doesn't pull `:ssl`,
  `tickets.ex` fails at runtime with `:undef` on `strong_rand_bytes/1` with no compile
  warning. Cheap to make explicit: add `:crypto` to `extra_applications`.
- **`priv/spike/latency_bench.exs` really does avoid `:inets`** — it authors a
  10-line hand-rolled HTTP/1.1 request over `:gen_tcp` (`priv/spike/latency_bench.exs:408-427`)
  specifically because `:inets` isn't in `extra_applications` and its own header
  comment documents why (`:httpc` would die on a missing `:http_util` under `mix run`).
  Confirmed no `:inets`/`:httpc` reference anywhere in `lib/` or `priv/`.
- **`mix.lock` hygiene**: no unused entries — every locked package resolves to either
  a direct dependency or a real transitive edge (`mix deps.tree` cross-checked
  against `mix.lock`). `mix_audit`'s transitive chain (`yaml_elixir`, `yamerl`) is
  correctly scoped `only: [:dev, :test]` via `mix_audit` itself, so it's excluded from
  a `MIX_ENV=prod` deps/compile pass — no dev-only leakage into prod.
