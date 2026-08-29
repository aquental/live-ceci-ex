# Dependency Audit — live_ceci

Date: 2026-08-29
Scope: supply-chain / version-constraint / maintenance-risk review. Vulnerability and
staleness scans already run and closed (`mix hex.audit`: no advisories; `mix deps.audit`:
no vulnerabilities; `mix hex.outdated`: everything up to date). This report covers
everything *those* tools cannot see.

No "unused dependency" findings — every entry in `mix.exs` (`bandit`, `plug`, `websockex`,
`websock_adapter`, `gemini_ex`, `jason`, `mix_audit`) has confirmed call sites in `lib/` or
`test/`.

---

## P1

### 1. `gemini_ex`'s documented safety net ("drift is a runtime error") is false for 3 of 4 integration points

`mix.exs:32-36` and `README.md:116` both justify the `~> 0.17.0` minor-pin by claiming that
if `gemini_ex` changes its struct/message shape, "drift surfaces as a runtime error, not a
compile one." That is only true for one of the four places this app touches `gemini_ex`
internals. The other three degrade **silently**:

- `lib/live_ceci/provider/gemini.ex:114` — `def translate(_other, _owner), do: :ok` catches
  anything that doesn't match `%ServerMessage{server_content: %ServerContent{}}`. If
  `gemini_ex` ever renames/restructures `ServerContent` (it already changed the Live
  transport once, in 0.16.0), voice output and barge-in (`interrupted`) stop working with
  **no log line, no crash, no test failure in prod** — audio just silently stops decoding.
- `lib/live_ceci/provider/gemini.ex:124` — `def translate_transcript(_other, _owner), do: :ok`
  is the same trap for transcripts.
- `lib/live_ceci/provider/gemini.ex:99` — `def handle_tool_call(_tool_call, _owner), do: :ok`
  is the same trap for tool dispatch (agendar/presença/recibo/resumo).

Only `lib/live_ceci/live_session.ex:33-39` (`GenServer.call` to the internal
`{:send_realtime_input, ...}` message) actually produces a catchable `{:error, {:exit,
reason}}`, and even that is logged only as `Logger.warning` (`socket.ex:86`), not raised.

Net effect: the pin protects compilation, but the comment overstates what happens at
runtime for 3 of 4 paths. The real safety net is the test suite
(`test/live_ceci/provider/gemini_test.exs` does construct real `Gemini.Types.Live.*`
structs, so a shape change would fail tests) — but there is no CI (see P2 §6) to run that
suite automatically on `mix deps.update`, so the net only fires if a human remembers to run
`mix test` after bumping `gemini_ex`.

**Fix**: either add explicit `else`/logging clauses instead of bare catch-alls (turn silent
`:ok` into a logged warning, mirroring `live_session.ex`), or correct the comment/README to
stop promising a runtime error that three of the four paths don't produce.

### 2. `gemini_ex` bus-factor and churn are high for a library whose internals this app calls directly

- Single maintainer (`nshkrdotcom`), 43 published versions to reach 0.17.0.
- Release cadence has been roughly every 1–3 weeks for the last several releases
  (0.13.0 and 0.12.0 same day 2026-04-02; 0.14.0 2026-06-16; 0.15.0 2026-07-27; 0.16.0
  2026-08-10; 0.17.0 2026-08-21 — 8 days before this audit).
- Adoption is small: 306 downloads in the last 30 days, 13,261 all-time, 4 dependants on
  Hex.
- `CHANGELOG.md` 0.16.0 confirms the exact risk `mix.exs:34` already warned about: "Replaced
  the Gun/Cowlib Live WebSocket stack with WebSockex" — a transport swap in a *minor*
  release, for a library this app pattern-matches structs from and calls an internal
  GenServer message on (`live_session.ex:33`).

The `~> 0.17.0` pin is doing real work and is the right call, but it only holds until the
next intentional bump. Given the combination of (single maintainer + internal-API coupling
+ demonstrated willingness to swap transports in a minor + no CI to gate the bump), an
upgrade to 0.18.x should be treated as a mandatory-review event, not a routine `mix
deps.update`, and the two call sites in Finding 1 should get explicit fallback logging
before that bump is attempted.

---

## P2

### 3. `websockex` and `websock_adapter` both use loose two-segment `~>` requirements on pre-1.0 packages

- `mix.exs:30` — `{:websockex, "~> 0.4"}` resolves to `>= 0.4.0 and < 1.0.0`.
- `mix.exs:31` — `{:websock_adapter, "~> 0.5"}` resolves to `>= 0.5.0 and < 1.0.0`.

For a 0.x package, Hex's own convention (and this project's own practice for `gemini_ex`,
`mix.exs:37`, `~> 0.17.0` three-segment) is to pin to the minor with a three-segment
requirement, because 0.x minor bumps are allowed to break under semver. A two-segment `~>`
on a 0.x dependency defeats that protection — `mix deps.update websock_adapter` could
legally jump to 0.99.0 without mix.exs ever needing to change.

Notably, `gemini_ex` itself is stricter about the same library than this app is:
`mix.lock` shows `gemini_ex` requires `{:websockex, "~> 0.5.1", ...}` (three-segment,
`>= 0.5.1 and < 0.6.0`), while this app's own direct requirement (`~> 0.4`) is looser than
what its own transitive dependency demands of the same package.

**Fix**: tighten both to three-segment requirements matching the resolved lock versions,
e.g. `{:websockex, "~> 0.5.1"}`, `{:websock_adapter, "~> 0.6.0"}`.

### 4. `websock` is a phantom direct dependency

`lib/live_ceci/socket.ex:32` declares `@behaviour WebSock` and uses `@impl WebSock` four
times — this is a compile-time contract with the `websock` package. `websock` is not listed
in `mix.exs` at all; it arrives transitively through `websock_adapter` (and `bandit`, which
also requires it). Nothing in this app's own dependency declarations protects that
`@behaviour` contract if `bandit` or `websock_adapter` ever relax or drop their `websock`
requirement.

**Fix**: add `{:websock, "~> 0.5"}` directly to `mix.exs`, matching the version this app's
code actually programs against.

### 5. `websockex`'s blast radius doubled without the app's mix.exs reflecting it, and its source link is stale

- `websockex` hex.pm ownership was transferred from the original maintainer (Azolo) to the
  `witchtails` organization on 2025-11-13; the actual maintenance is by Dominic Letz
  (`witchtails/websockex_wt`, a fork of `dominicletz/websockex`), with two releases since
  (0.5.0 on 2025-11-23, 0.5.1 on 2025-12-01). This is **not abandonment** — it's active,
  named maintenance — but it is a maintainer change less than a year old for a package that
  is now load-bearing for *two* independent things:
  1. `LiveCeci.Provider.Grok` (`lib/live_ceci/provider/grok.ex`), hand-rolled, as documented.
  2. As of `gemini_ex` 0.16.0 (2026-08-10), `gemini_ex`'s own Live WebSocket transport also
     now runs on WebSockex (replacing Gun/Cowlib) — confirmed in
     `deps/gemini_ex/CHANGELOG.md`.

  A regression in `websockex` today would take down *both* voice backends, not just the
  Grok path the mix.exs comment (`mix.exs:27-29`) frames it around. Worth re-reading that
  comment's "already in the tree via gemini_ex" note in light of this — it's still true, but
  the reason it's true has changed (used to be an unrelated transitive dep; now it's the
  same transport gemini_ex itself relies on).
- Cosmetic but worth fixing while touching this: `deps/websockex/mix.exs` (the installed
  package's own metadata) still declares `source_url: "https://github.com/Azolo/websockex"`
  even though the maintainer/package field points at
  `"https://github.com/witchtails/websockex_wt"`. Not something this app controls, but
  don't trust the `source_url` in HexDocs for this package — use the `links` field.

### 6. No toolchain pin and no CI — reproducibility rests on this one machine's state

- `mix.exs:8` — `elixir: "~> 1.17"` resolves to `>= 1.17.0 and < 2.0.0`: any future 1.x is
  accepted, unbounded.
- No `.tool-versions`, no `.mise.toml`, nothing pinning an Elixir/OTP pair anywhere in the
  repo.
- No CI config found anywhere in the repo (`find . -iname "*.yml" -o -iname "*.yaml"`
  returned nothing outside `deps/`/`_build/`).
- The machine this audit ran on is already on Elixir 1.20.4 / OTP 29 — several minors ahead
  of anything the `~> 1.17` floor was written against, and there is no automated job that
  has ever compiled+tested this exact combination other than this ad hoc session.

Combined with Findings 1–2 (an upstream dependency that changes internals on minor bumps),
the absence of CI means the one thing that would actually catch a `gemini_ex`/`websockex`
regression automatically — `mix compile --warnings-as-errors && mix test` running on every
dependency bump — doesn't exist. `mix_audit` (`mix.exs:41`) only catches *known* CVEs, not
API drift.

**Fix**: add a `.tool-versions` (or `.mise.toml`) pinning the exact Elixir/OTP pair this app
is verified against, and a minimal CI workflow running
`mix deps.get && mix compile --warnings-as-errors && mix format --check-formatted && mix test`
at minimum on every push/PR.

---

## P3

None.
