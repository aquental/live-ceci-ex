# Security Audit: live-dj (Elixir/OTP)

**Date**: 2026-08-28
**Scope**: `lib/live_dj/{router,socket,tools}.ex`, secret handling, `priv/frontend/*`
**Stack**: Bandit + Plug.Router + raw `WebSock` -> `gemini_ex` Live session. No Phoenix, no Ecto, no DB, no auth system.

## Executive Summary

The application code is small and defensively written; the injection/XSS/secret-in-code
classes are all clean. The entire risk sits in one place: **`/ws` is a completely
unauthenticated, unrestricted, unmetered proxy to the Gemini Live API on the operator's
API key.** Anyone who can reach the port — and, because WebSocket handshakes are exempt
from the same-origin policy, any website a victim visits — can open a session and spend
the operator's quota indefinitely. Two P1s, one P2, four P3s.

---

## P1 — Cross-Site WebSocket Hijacking: `/ws` does not check `Origin`

- **Severity**: P1
- **Location**: `lib/live_dj/router.ex:24-28`
- **OWASP**: A01 Broken Access Control / CWE-1385 (Missing Origin Validation in WebSockets)

**Attack.** The browser's same-origin policy does not apply to `WebSocket`. It sends no
preflight and the SOP does not block the handshake. Any page on the internet can run:

```js
new WebSocket("ws://localhost:8000/ws")  // or wss://your-deployed-host/ws
```

and get a fully functional Live session. On a developer's machine `evil.com` silently
opens a session against `localhost:8000` in the background of an unrelated tab. On a
deployed instance every origin on the internet is trusted. The socket has no cookies or
credentials, so there is nothing to *steal* — the damage is that the attacker gets free
use of the operator's Gemini key, and can drive the model with attacker-chosen audio
whose transcripts land in the operator's logs and billing record.

**Fix.** Reject unknown origins before the upgrade. Origin is attacker-spoofable from a
non-browser client (so this is not authentication — see the next finding), but it is the
control that stops the drive-by-from-a-web-page vector.

```elixir
@allowed_origins Application.compile_env(:live_dj, :allowed_origins, ["http://localhost:8000"])

get "/ws" do
  case get_req_header(conn, "origin") do
    [origin] when origin in @allowed_origins ->
      conn
      |> WebSockAdapter.upgrade(LiveDJ.Socket, [], timeout: 60_000, max_frame_size: 1_000_000)
      |> halt()

    _ ->
      conn |> send_resp(403, "forbidden") |> halt()
  end
end
```

Make the allowlist runtime config (`ALLOWED_ORIGINS` in `runtime.exs`) so deploys can set
their real host.

---

## P1 — Unauthenticated, uncapped session fan-out: one HTTP request = one paid upstream session

- **Severity**: P1
- **Location**: `lib/live_dj/router.ex:24-28` (no auth, no cap), `lib/live_dj/socket.ex:42-86` (unconditional `Session.start_link` + `Session.connect`)
- **OWASP**: A04 Insecure Design / A07 Identification and Authentication Failures; CWE-770 (Allocation Without Limits)

**Attack.** `init/1` unconditionally opens a `Gemini.Live.Session` for every accepted
socket. There is no ticket, no token, no per-IP limit, and no global concurrency cap.
A trivial script opens 5,000 sockets; the server opens 5,000 billed upstream Live
sessions, 5,000 outbound WebSockets to Google, and 5,000 BEAM processes. This is
simultaneously:

1. **Financial DoS** — Live API audio sessions are billed per second of audio in/out.
   The attacker's only cost is holding TCP connections.
2. **Availability DoS** — file descriptors, Google-side per-project concurrent-session
   quota (a small number), and memory. Exhausting the upstream quota takes the app down
   for legitimate users even if the BEAM survives.
3. **Upstream abuse laundering** — see P2 below; arbitrary attacker bytes are relayed to
   Google under the operator's project identity.

Note the interaction with `timeout: 60_000`: that is an *idle* timeout, reset by every
inbound frame. A client that sends one byte every 30s holds a paid session forever.
There is no maximum session lifetime anywhere.

**Fix.** Three layers, all cheap:

```elixir
# 1. A short-lived, single-use ticket minted by an authenticated HTTP route.
#    Even for a demo, an unguessable ticket is what separates "my users" from "the internet".
get "/ws" do
  with [t] <- get_req_header(conn, "sec-websocket-protocol") || fetch_query_params(conn).params["t"],
       :ok <- LiveDJ.Ticket.consume(t) do
    conn |> WebSockAdapter.upgrade(...) |> halt()
  else
    _ -> conn |> send_resp(401, "unauthorized") |> halt()
  end
end
```

```elixir
# 2. A hard global cap, checked BEFORE the upgrade and released in terminate/2.
#    :counters is lock-free and safe on the accept path.
defmodule LiveDJ.SessionCap do
  @max 20
  def acquire do
    if :counters.get(ref(), 1) >= @max, do: :error, else: (:counters.add(ref(), 1, 1); :ok)
  end
  def release, do: :counters.sub(ref(), 1, 1)
  # ref/0: a :counters ref stashed in :persistent_term at boot
end
```

```elixir
# 3. A maximum session lifetime, so an idle-timeout-defeating client still gets evicted.
def init(_opts) do
  Process.send_after(self(), :max_lifetime, :timer.minutes(30))
  ...
end
def handle_info(:max_lifetime, state), do: {:stop, :normal, state}
```

Add a per-IP cap (2-3 concurrent) alongside the global one; `remote_ip` is available on
`conn` at upgrade time. If the app is behind a proxy, only trust `x-forwarded-for` via
`RemoteIp` with a configured proxy allowlist.

---

## P2 — Unvalidated, unmetered binary pass-through to the upstream API

- **Severity**: P2
- **Location**: `lib/live_dj/socket.ex:91-105`; frame ceiling at `lib/live_dj/router.ex:26`
- **OWASP**: A03 Injection (untrusted data forwarded to a downstream interpreter) / CWE-20

**Attack.** `handle_in/2` takes whatever binary the browser sent and hands it straight to
`LiveDJ.LiveSession.send_audio/2`, which wraps it in `Audio.create_input_blob/1` and ships
it upstream labelled as 16 kHz PCM. Nothing checks that it *is* PCM, that its length is
even (a hard requirement for s16le), or that the client is sending at anything like
real-time rate.

`max_frame_size: 1_000_000` caps a single frame but not the stream. A client can push
1 MB frames back to back; each is base64-expanded to ~1.33 MB on the wire to Google. The
practical bound is the 1s `@send_timeout` in `LiveDJ.LiveSession` (which serialises one
frame at a time per socket), so a *single* socket is partly self-limiting — but combined
with the missing connection cap in P1, N sockets multiply it linearly.

The frontend sends ~100 ms batches: at 16 kHz mono s16le that is **3,200 bytes**. The
1 MB ceiling is ~300x larger than any legitimate frame.

**Fix.**

```elixir
# router.ex — size the ceiling to the actual protocol, with headroom for jitter batching.
|> WebSockAdapter.upgrade(LiveDJ.Socket, [], timeout: 60_000, max_frame_size: 64_000)
```

```elixir
# socket.ex — validate the shape, and meter the rate.
@max_pcm_bytes 64_000
@bytes_per_second 32_000                    # 16 kHz * 2 bytes, mono
@burst_bytes @bytes_per_second * 5          # 5s of slack

def handle_in({pcm, [opcode: :binary]}, %{session: session} = state)
    when session != nil and byte_size(pcm) <= @max_pcm_bytes and rem(byte_size(pcm), 2) == 0 do
  case take_budget(state, byte_size(pcm)) do
    {:ok, state} -> ...existing send_audio call...
    :over_budget -> {:stop, :normal, 1008, error_frame(:rate), state}
  end
end

# Anything malformed or oversized: drop the frame, do not forward it upstream.
def handle_in({_pcm, [opcode: :binary]}, state), do: {:ok, state}
```

`take_budget/2` is a token bucket over `System.monotonic_time/1` held in the socket
state — no extra process, no ETS.

---

## P3 — `Plug.Static` at `/` has no `only:` allowlist

- **Severity**: P3
- **Location**: `lib/live_dj/router.ex:19`

The `priv/assets` mount above it correctly uses an allowlist and the comment explains why.
The `priv/frontend` mount has no such guard: **every** file in that directory is world
-readable, now and forever. Today that is exactly the three intended files, so there is no
live exposure — but the invariant is only maintained by nobody ever dropping a
`main.js.map`, `notes.md`, `index.html.bak`, or a stray `.env` copy into the directory.
The whole point of the allowlist discipline applied one line above is that it survives the
next commit.

**Fix.**

```elixir
plug Plug.Static,
  at: "/",
  from: {:live_dj, "priv/frontend"},
  only: ~w(index.html main.js pcm-processor.js),
  index: ["index.html"]
```

---

## P3 — Upstream error terms are `inspect/1`'d into logs without redaction

- **Severity**: P3
- **Location**: `lib/live_dj/socket.ex:80, 102, 136, 141, 146, 157`

The client-facing leak **is fixed and verified**: `error_frame/1` (`socket.ex:202-204`)
discards its argument and emits a fixed string, and both call sites (`:80`, `:136`) log the
detail separately. That is the right split.

The remaining exposure is log-side. `gemini_ex` puts the API key directly in the upstream
WebSocket URL query string:

```
deps/gemini_ex/lib/gemini/client/websocket.ex:553
    "#{gemini_path(conn.api_version)}?key=#{api_key}"
```

and that URL is passed into the transport at `:502`. The library treats this path as
sensitive — its own logging routes through `redact_websocket_path/1` at `:500`. The app
applies no equivalent filter to the arbitrary upstream terms it inspects. The
`{:error, reason}` catch-all at `websocket.ex:512` can surface library structs whose
contents are not under this app's control.

Mitigating factor, verified: `LiveDJ.Socket` calls `Session.start_link/1` without an
`:api_key` option, so `state.config.api_key` inside the `Gemini.Live.Session` GenServer is
`nil` (`deps/gemini_ex/lib/gemini/live/session.ex:324`). A default OTP crash report for
that process therefore will not dump the key in its `State:` line. The risk is confined to
transport-level error terms.

**Fix.** One redaction helper on the way to `Logger`:

```elixir
defp redact(term) do
  term
  |> inspect(limit: 50, printable_limit: 500)
  |> String.replace(~r/key=[^\s&"\)\]]+/, "key=<redacted>")
end
```

Use `redact(reason)` in place of `inspect(reason)` at all six sites. Also set
`config :logger, :console, metadata: []` (already the case) and avoid `:debug` level in
production (`config/prod.exs` correctly pins `:info`) — `websocket.ex:500` logs the path at
`:debug`, redacted, but there is no reason to run at that level in prod.

---

## P3 — `String.to_atom/1` in `tools.ex`: NOT exploitable (conclusion + evidence)

- **Severity**: P3 (hygiene only — no vulnerability)
- **Location**: `lib/live_dj/tools.ex:77`

```elixir
defp arg(args, key) when is_map(args), do: args[key] || args[String.to_atom(key)] || ""
```

**Conclusion: the `key` argument is never attacker- or model-controlled.** Evidence:

1. `arg/2` is `defp` — unreachable from outside the module. No `apply/3`, no
   `Function.capture`, no re-export anywhere in `lib/`.
2. It has exactly two call sites, both in `dispatch/2` clause *bodies*, both passing a
   compile-time string literal:
   - `tools.ex:68` — `arg(args, "mood")`
   - `tools.ex:71` — `arg(args, "title")`
3. The model controls two things and neither reaches `key`:
   - `name` (`dispatch/2` first arg) — routed by literal pattern match with a catch-all at
     `tools.ex:75` that interpolates the name into a *string*, never an atom.
   - `args` (the map) — flows into `arg/2` as the **first** parameter, the map being read,
     not the key.
4. The reachable atom set is therefore `{:mood, :title}` — two atoms, both already
   interned at compile time by the `@declarations` module attribute. No unbounded growth,
   no atom-table exhaustion.

**Why fix it anyway.** It is a loaded footgun one refactor away from being live: the day
someone writes `arg(args, some_dynamic_name)`, this becomes a remote DoS with no visible
diff at the call site. The atom lookup is also unnecessary — `gemini_ex` decodes tool-call
args from JSON, so the keys are strings.

```elixir
@arg_keys %{"mood" => :mood, "title" => :title}
defp arg(args, key) when is_map(args), do: args[key] || args[@arg_keys[key]] || ""
defp arg(_args, _key), do: ""
```

This keeps the string-or-atom tolerance, cannot mint an atom at runtime under any input,
and fails closed (`nil` lookup -> `""`) if a key is ever added to `dispatch/2` without
being added here.

---

## P3 — Model-controlled tool arg is untyped and crashes the client's message loop

- **Severity**: P3 (availability nit)
- **Location**: `lib/live_dj/tools.ex:68, 71` -> `priv/frontend/main.js:47, 88`

`arg/2` returns `args["mood"]` verbatim with no type check; the `@type play_command`
spec promises `String.t()` but nothing enforces it. If the model emits
`{"title": 42}` or `{"title": {...}}`, the value is JSON-encoded and forwarded, and the
browser does:

```js
tracks.find((x) => x.title.toLowerCase().includes((cmd.value || "").toLowerCase()));
```

`42.toLowerCase` is a `TypeError`. It is thrown inside `ws.onmessage` with no handler, so
the exception propagates out of the event callback — the socket stays open but that message
is lost, and `JSON.parse(evt.data)` at `main.js:88` is likewise unguarded. Not a security
boundary (the model, not the user, supplies this), but it is untrusted-by-default data
reaching a sink.

**Fix.** Coerce server-side, where the contract is defined:

```elixir
defp arg(args, key) when is_map(args) do
  case args[key] || args[@arg_keys[key]] do
    v when is_binary(v) -> v
    _ -> ""
  end
end
```

and defensively wrap the client handler in `try { ... } catch (e) { console.error(e) }`.

---

## P3 — `.claude/` is not gitignored

- **Severity**: P3
- **Location**: `.gitignore` (absent), `.dockerignore:12` (present)

`.dockerignore` excludes `.claude/` from the image; `.gitignore` does not exclude it from
the repo. Audit reports are committed, and by construction they enumerate the application's
weaknesses and file:line locations. For a public repo that is a free reconnaissance map.

**Verified**: the archived report at
`.claude/audit/archive/2026-08-28-pre-cleanup/security-audit.md` contains **no** API key
material — no `AIza`-prefixed string anywhere in the tree, and the only 25+ character
token in that file is the identifier `put_secure_browser_headers` on line 328. The earlier
leak is not present in the current working tree.

**Fix.** Decide deliberately: either add `.claude/` to `.gitignore`, or keep it committed
and accept that findings are public. Do not leave it accidental.

---

## Verification requested by scope (results)

**`priv/assets` allowlist — CONFIRMED EFFECTIVE.** `mira_persona.txt` is not reachable.
Traced through `deps/plug/lib/plug/static.ex`:

- `path_status/2` at `:242-248` tests **only the first segment after `at:`** against the
  `:only` list. For `GET /assets/mira_persona.txt` the head segment is
  `"mira_persona.txt"`, which is not in `~w(tracks tracks.json)`, so the plug declines and
  passes the conn through.
- The request then hits the second `Plug.Static` at `/` from `priv/frontend`, which
  resolves `priv/frontend/assets/mira_persona.txt` — nonexistent — and also passes through.
- It lands on `match _` (`router.ex:36`) -> **404**.
- Traversal is closed too: `invalid_path?/2` at `:480-482` rejects any segment equal to
  `.`, `..`, or `""`, or containing `/`, `\`, `:`, or `\0`. `/assets/tracks/../mira_persona.txt`
  is refused before any filesystem access.
- Nothing else in `priv/` is exposed by the second mount: its `from:` root is
  `priv/frontend`, which cannot reach `priv/assets` (see the P3 above for the *future*
  risk of that directory having no allowlist).

**Client-facing error leak — CONFIRMED FIXED.** `error_frame/1` (`socket.ex:202-204`)
ignores `reason` entirely and returns a constant `"the line dropped — try again"`. Both
call sites log the real reason server-side. No quota state, billing state, or key-bearing
URL can reach the browser through this path.

**XSS — no sinks.** Every transcript path uses `textContent`: `main.js:20` (`setStatus`),
`:28` (`addLine`, the model-generated transcript), `:43` (`setNow`). No `innerHTML`, no
`outerHTML`, no `insertAdjacentHTML`, no `document.write`, no `eval`, no
`new Function`. `index.html` has no interpolation — it is a static document with static
inline CSS.

**Secrets — no path to a build artifact or the browser.** `.env` is gitignored
(`.gitignore:14`) and dockerignored (`.dockerignore:2`). No tracked file contains an
`AIza`-prefixed value. `.env.example` holds only the placeholder `your-key-here`. The key
is read at runtime in `config/runtime.exs:23` and handed to `:gemini_ex` application env;
it is never compiled into a `.beam`, never written to `priv/`, and never crosses the
WebSocket to the client. `LiveDJ.config/0` exposes only `model`, `voice`, and `port`.

> **Not verifiable by this agent (no Bash access) — please run manually:**
> ```
> git log --all --full-history -- .env
> ```
> A clean `git status` with `.env` present on disk is consistent with "untracked" but does
> not by itself prove `.env` was never committed on an earlier commit or a deleted branch.
> If that command returns any commit, the key must be rotated in AI Studio and the history
> rewritten (`git filter-repo --path .env --invert-paths`) — gitignoring a file does not
> remove it from history.

---

## Clean areas (no findings)

SQL injection, CSRF, changeset validation, LiveView authorization: **no such surface
exists** in this app. Also checked and clean: no `binary_to_term`, no `:erlang.apply` on
untrusted input, no `Code.eval_*`, no `System.cmd`/`os:cmd`, no user-controlled `File.*`
or path construction, no hardcoded secrets, no `raw`-equivalent HTML sink, correct
supervision (`application.ex:11-19`), and `mix.exs:33` pins `gemini_ex` to the minor with
`mix_audit` present.

---

## Recommendations (priority order)

1. **Origin allowlist on `/ws`** (P1) — one `case` in the router; stops drive-by sessions.
2. **Global + per-IP concurrency cap, and a max session lifetime** (P1) — the single
   highest-value change; without it the app is a public spend endpoint.
3. **A connection ticket** (P1) — the only real authentication; Origin is spoofable by
   non-browser clients.
4. **Drop `max_frame_size` to ~64 KB, validate frame shape, add a token bucket** (P2).
5. **`only:` on the `priv/frontend` static mount** (P3).
6. **`redact/1` helper for all `inspect(reason)` log sites** (P3).
7. **`@arg_keys` map replacing `String.to_atom/1`** (P3) — not a live bug; removes the
   footgun.
8. **Coerce tool args to strings server-side; guard `JSON.parse` client-side** (P3).
9. **Decide `.claude/` gitignore policy** (P3).
10. **Security headers** — a small `put_resp_header` plug before `:match`:
    `x-content-type-options: nosniff`, `referrer-policy: no-referrer`,
    `content-security-policy: default-src 'self'; connect-src 'self' ws: wss:; media-src 'self'; frame-ancestors 'none'; style-src 'unsafe-inline'`.
    Note `style-src 'unsafe-inline'` is required by the inline `<style>` in `index.html`;
    move it to a `.css` file to drop that exception. Add HSTS when TLS is terminated.

## Tools to run manually (this agent has no Bash access)

```
git log --all --full-history -- .env     # the outstanding secret-history check
mix deps.audit                            # mix_audit is already in deps
mix hex.audit
mix compile --warnings-as-errors && mix format --check-formatted
```

`mix sobelow` is Phoenix-specific and will find little here; the audit above covers the
non-Phoenix surface directly.
