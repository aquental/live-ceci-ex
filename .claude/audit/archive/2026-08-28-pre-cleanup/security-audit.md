# Security Audit: live-dj-ex

Scope: plain Elixir/Bandit/Plug app, one unauthenticated WebSocket bridging browser
audio to the Gemini Live API. No Phoenix/Ecto/DB/accounts/sessions — those categories
are out of scope and not reported. sobelow is not applicable.

Tooling note: this agent has no Bash access. Git facts below were established by
reading `.git/index`, `.git/logs/HEAD`, and `.gitignore` directly.

---

## PRIORITY 1 — Secret handling

### 1.1 `.env` git status — VERDICT

**Verdict: CLEAN. `.env` is gitignored and is NOT tracked, and there is no evidence it
was ever committed.**

Evidence:

- `/Users/aquental/projects/ai/google/live-dj-ex/.gitignore:14` contains `.env`
  (under the comment `# your key lives here`).
- `.git/index` (read directly) lists every tracked path. It contains
  `.env.example` but **does not contain `.env`**. So `git ls-files --error-unmatch .env`
  would fail → not tracked at HEAD.
- Working tree is clean per `git status`. A tracked-and-modified `.env` would show as
  modified; an untracked-and-unignored `.env` would show as untracked. Neither appears,
  which is consistent only with "ignored".
- `.git/logs/HEAD` shows exactly two local commits:
  `ab380fa` (initial) → `e1a3ed3` (merge of remote LICENSE/.gitignore). The `REUC`
  record in `.git/index` shows `.gitignore` existed on **both** sides of that merge
  (stage 1 = 0, stages 2 and 3 present), i.e. the local initial commit already carried
  a `.gitignore`. There is no third commit that could have deleted a previously
  committed `.env`. Therefore `.env` was never in history.
- Residual verification the user can run in one second (I cannot exec):
  `git check-ignore -v .env && git ls-files --error-unmatch .env ; git log --all --oneline -- .env`
  Expected: check-ignore prints `.gitignore:14:.env`, ls-files errors, log is empty.

**However** — `/Users/aquental/projects/ai/google/live-dj-ex/.env:3` contains what is by
format a **live Google AI Studio key** (`GOOGLE_API_KEY=<redacted>`), in plaintext on
disk. Severity **High** as an operational matter, not as a git leak:

- It is readable by any process/user with filesystem access, any editor plugin, any
  `mix` task, and any AI/agent tool pointed at the repo (including this audit — the
  value entered a model context).
- Any future `git add -f`, `git stash -u`, `tar`/`zip` of the directory, Docker
  `COPY . .` (there is no `.dockerignore` in the repo), or CI artifact upload ships it.
- **Fix**: rotate the key in AI Studio now (it has been read by tooling), keep the new
  one only in the shell environment or a secret manager, and add a `.dockerignore`
  containing `.env` before any container build.

### 1.2 Hand-rolled dotenv parser — arbitrary env-var injection

- **Severity**: Medium
- **Location**: `config/runtime.exs:6-20`
- **Issue**: the parser splits every non-comment line on the first `=` and calls
  `System.put_env(key, value)` for **any** key, with no allow-list. Consequences:
  1. **Env injection.** Anyone who can write `.env` in the app's config-relative
     directory sets arbitrary OS env vars in the running BEAM. This is not theoretical
     given the stated design goal ("so `.env` from the Python repo works unchanged") —
     a `.env` copied from another repo or received from a third party is executed as
     configuration. Concretely dangerous keys: `HTTPS_PROXY`/`HTTP_PROXY` (redirects the
     outbound Gemini TLS session through an attacker MITM, exposing the API key in the
     `?key=` query string), `SSL_CERT_FILE`/`ERL_SSL_*`, `PATH` (affects any port/NIF
     spawned later), and `PORT`/`SOCKET_HANDLER` (silently swaps the socket handler to
     `LiveDJ.Minimal`, which has no persona and no tools).
  2. **Boot-time crash / bad keys.** `export FOO=bar` yields key `"export FOO"`;
     `System.put_env/2` with a name containing `=`/NUL raises, aborting boot. A `.env`
     containing a `=` in a comment-less garbage line is a DoS on startup.
  3. Values are only conditionally applied (`if System.get_env(key) == nil`), so a real
     deployment that sets env directly is not overridden — that part is correct.
- **Fix**:

  ```elixir
  @allowed ~w(GOOGLE_API_KEY GEMINI_API_KEY LIVE_MODEL LIVE_VOICE PORT SOCKET_HANDLER)

  if File.exists?(env_file) do
    env_file
    |> File.stream!()
    |> Enum.each(fn line ->
      with trimmed <- String.trim(line),
           false <- trimmed == "" or String.starts_with?(trimmed, "#"),
           [key, value] <- String.split(trimmed, "=", parts: 2),
           key <- String.trim(key),
           true <- key in @allowed,
           nil <- System.get_env(key) do
        System.put_env(key, value |> String.trim() |> String.trim(~s(")) |> String.trim("'"))
      end
    end)
  end
  ```

  Better still in production: skip the file entirely when `config_env() == :prod`.

- **Logging**: confirmed no code path logs `.env` values or the API key. The `IO.warn`
  at `config/runtime.exs:29-33` prints only when the key is **absent** and contains no
  secret. `Logger.info` at `lib/live_dj/socket.ex:69` logs model and voice only.
  `config/config.exs:9-11` sets `metadata: []`, so no metadata leakage.

### 1.3 `config/test.exs` literal `api_key: "test-key"` — cannot leak

- **Verdict: not a finding.** `config/config.exs:13` does
  `import_config "#{config_env()}.exs"`, which is resolved at **compile time** against
  `MIX_ENV`. `config/test.exs:6` is therefore only compiled into a `MIX_ENV=test` build,
  and even there `config/runtime.exs:26` overrides `:gemini_ex, :api_key` at boot when a
  real key is present. It is a dummy string with no value if disclosed. No change needed.

### 1.4 Unauthenticated internal-error disclosure to the browser (`error_frame/1`)

- **Severity**: High
- **Location**: `lib/live_dj/socket.ex:193-195`, reached from `:80` (session open
  failure) and `:131` (`{:gemini_error, reason}`)
- **Issue**: `inspect(reason)` on an upstream Gemini/WebSockex error term is serialized
  into `{"type":"error","message": ...}` and pushed to an **unauthenticated remote
  client**, which renders it (`priv/frontend/main.js:86`) and console-logs it. Traced
  what `reason` can be:
  - `{:upgrade_failed, status, Exception.message(%WebSockex.RequestError{})}` —
    `deps/gemini_ex/lib/gemini/client/websocket.ex:506-507`
  - `{:open_failed, reason}` / `{:upgrade_error, reason}` — `:509-513`
  - `{:max_retries_exceeded, reason}` — `:489`
  - `{:closed, code, reason}` / `{:connection_down, reason}` — `:324, :328`
  - `{:exit, reason}` — `:279, :346`

  Two distinct impacts:

  1. **Confirmed leak — upstream internals.** Google's Live API close reasons and
     upgrade errors are echoed verbatim: quota state, billing/project hints, exact model
     ID, API version, "API key not valid"/"API key expired" distinctions, and library
     internals. An anonymous attacker gets a free oracle on the operator's Google
     account state and can distinguish "key revoked" from "quota exhausted" from
     "model unavailable" — useful for confirming a successful quota-exhaustion attack
     (see 2.1).
  2. **Credential-leak potential — not confirmed, but real.** The upstream URL is
     `wss://generativelanguage.googleapis.com/...?key=<API_KEY>`
     (`deps/gemini_ex/lib/gemini/client/websocket.ex:553`). The library is careful to
     redact it on its own debug path (`@redact_query_params ~w(key access_token token)`,
     `:135`, `:500`, `:576-578`) — the maintainers clearly treat this URL as a secret.
     But the `{:upgrade_error, reason}` and `{:exit, reason}` branches are opaque
     pass-throughs: if `WebSockex.start/3` fails with an exception+stacktrace tuple, or
     a transport process exits carrying its `%WebSockex.Conn{}` (which holds the full
     key-bearing URL), `inspect/1` renders it in full and the app ships it to the
     browser. I traced `%WebSockex.RequestError{}` (code + message) and
     `%WebSockex.ConnError{original:}` and neither carries the URL — so this is a
     latent path, not a demonstrated one. It should not be left to chance.
- **Fix**: never send raw terms to the client. Log the detail server-side, send a
  fixed string.

  ```elixir
  defp error_frame(reason) do
    Logger.error("live session error: #{inspect(reason)}")
    json(%{type: "error", message: "the line dropped — try again"})
  end
  ```

  If a code is genuinely useful to the UI, map it to a closed set
  (`:unavailable | :rate_limited | :internal`) explicitly.
- **OWASP**: A09:2021 Security Logging and Monitoring Failures / CWE-209 Generation of
  Error Message Containing Sensitive Information.

### 1.5 API key may appear in crash reports / SASL logs

- **Severity**: Medium
- **Location**: `deps/gemini_ex/lib/gemini/client/websocket.ex:553` (URL construction);
  no mitigation configured in `config/config.exs`
- **Issue**: the transport process (`deps/gemini_ex/lib/gemini/client/websocket/transport.ex:20-30`)
  is started from a `%WebSockex.Conn{}` built from the key-bearing URL. An abnormal exit
  of that process produces an OTP crash report that can include the process state and
  initial-call arguments — i.e. the URL with `?key=<API_KEY>` — written to whatever
  ships the app's logs. The library redacts its own debug line but cannot redact OTP's.
- **Fix**: add a Logger filter that scrubs `key=` from formatted messages, and keep
  `handle_sasl_reports` off in production:

  ```elixir
  # config/config.exs
  config :logger, handle_sasl_reports: false

  # a primary filter, installed at boot
  :logger.add_primary_filter(:redact_api_key, {&LiveDJ.LogRedactor.filter/2, []})
  ```

  where the filter rewrites `~r/key=[A-Za-z0-9._\-]+/` to `key=[REDACTED]`.

---

## PRIORITY 2 — The unauthenticated WebSocket

### 2.1 `GET /ws` has no authentication — direct billing/quota theft

- **Severity**: Critical
- **Location**: `lib/live_dj/router.ex:21-29`
- **Issue**: the upgrade is unconditional. There is no token, no session, no shared
  secret, no allow-list. Every accepted socket calls `Session.start_link/1` +
  `Session.connect/1` (`lib/live_dj/socket.ex:73-74`), opening a **new upstream Gemini
  Live session billed to the operator's key**. `LiveDJ.Application` starts Bandit with
  `{Bandit, plug: LiveDJ.Router, port: port}` (`lib/live_dj/application.ex:12`) and no
  `ip:` option, so it binds all interfaces — anything routable to the host is a client.
- **Exploit**: `for i in $(seq 1 500); do websocat ws://host:8000/ws < noise.pcm & done`.
  Each connection streams 16 kHz PCM upstream for up to 60 s of idle tolerance, with no
  cap on total connections. Gemini Live audio is billed per input/output token; a
  laptop can saturate the operator's quota and run up the bill in minutes, then confirm
  success by reading the quota-exhaustion string echoed back by `error_frame/1` (1.4).
  Secondary abuse: the attacker gets a free, anonymous, unattributable Gemini Live
  endpoint (content sent under the operator's key and TOS liability).
- **Fix**: this is the one change that matters most. Minimum viable gate:

  ```elixir
  get "/ws" do
    with :ok <- check_origin(conn),
         :ok <- LiveDJ.Auth.verify_ticket(conn.params["ticket"]),
         :ok <- LiveDJ.Limiter.allow(peer_ip(conn)) do
      conn
      |> WebSockAdapter.upgrade(handler, [], timeout: 60_000, max_frame_size: 1_000_000)
      |> halt()
    else
      _ -> conn |> send_resp(403, "forbidden") |> halt()
    end
  end
  ```

  The ticket is a short-TTL HMAC minted by an authenticated HTTP route
  (`Plug.Crypto.sign/3` + `verify/4` with `max_age: 60`); it is single-use and bound to
  the peer IP. If the app is genuinely meant to be public, put it behind an
  authenticating reverse proxy and never expose port 8000 directly.
- **OWASP**: A01:2021 Broken Access Control / A04:2021 Insecure Design
  (unrestricted resource consumption of a paid third-party API).

### 2.2 No `Origin` check — Cross-Site WebSocket Hijacking

- **Severity**: High
- **Location**: `lib/live_dj/router.ex:26-28`
- **Issue**: `WebSockAdapter.upgrade/4` performs no origin validation, and none is done
  in the router. WebSocket handshakes are not subject to the same-origin policy and are
  not blocked by CORS. Phoenix's `check_origin` default is absent here because there is
  no Phoenix endpoint.
- **Exploit**: a developer runs the app on `localhost:8000` and browses to any hostile
  page. That page executes `new WebSocket("ws://localhost:8000/ws")` and now (a) drives
  the developer's Gemini key at will, (b) receives all `transcript` frames, and
  (c) port-scans/fingerprints the local machine via connect success/failure. Because
  there are no cookies to steal the classic CSWRF impact is limited, but the cost
  amplification and the local-service discovery are real. This is the standard reason
  Phoenix ships `check_origin: true` by default.
- **Fix**: validate the header before upgrading.

  ```elixir
  @allowed_origins Application.compile_env(:live_dj, :allowed_origins, ["http://localhost:8000"])

  defp check_origin(conn) do
    case get_req_header(conn, "origin") do
      [origin] when origin in @allowed_origins -> :ok
      [] -> :ok            # non-browser client; gate it with the ticket instead
      _ -> {:error, :bad_origin}
    end
  end
  ```

  Note the `[] -> :ok` branch only holds once 2.1 is fixed; without a ticket it is a
  hole a non-browser client walks straight through.

### 2.3 No connection cap, no rate limit — resource exhaustion

- **Severity**: High
- **Location**: `lib/live_dj/router.ex:27`, `lib/live_dj/application.ex:11-13`
- **Issue**: Bandit is started with default `thousand_island_options`, so there is no
  `max_connections` bound configured, and there is no per-IP limiter anywhere. Each
  accepted socket costs one BEAM process **plus one outbound TLS WebSocket to Google**
  plus one `Gemini.Live.Session` GenServer. `timeout: 60_000` is an idle timeout only —
  a client that sends one frame per 59 s holds a session and its upstream connection
  indefinitely at near-zero attacker cost. `max_frame_size: 1_000_000` bounds a single
  frame but not the rate: a client can send 1 MB frames back-to-back, and
  `handle_in/2` forwards each one upstream with no backpressure, buffering, or
  accounting (`lib/live_dj/socket.ex:87-98`).
- **Fix**: bound all three dimensions.

  ```elixir
  {Bandit,
   plug: LiveDJ.Router,
   port: port,
   thousand_island_options: [num_acceptors: 10, max_connections: 50],
   http_options: [log_protocol_errors: false]}
  ```

  plus `max_frame_size: 65_536` (a 16 kHz s16le frame from the AudioWorklet is a few KB;
  1 MB is ~32 seconds of audio in one frame and is 15x larger than anything the real
  client sends), a shorter `timeout: 15_000`, and a per-IP connection counter plus a
  bytes-per-second budget enforced in `handle_in/2` that closes the socket on breach.

### 2.4 `Plug.Static` at `/` with no `only:` — unintended file exposure

- **Severity**: Medium
- **Location**: `lib/live_dj/router.ex:13` and `:16`
- **Issue**: **No path traversal** — `Plug.Static` rejects `..` segments and null bytes
  and refuses to escape `from:`; that is safe. The problem is scope. Neither plug sets
  `only:`/`only_matching:`, so *everything* under `priv/frontend` and `priv/assets` is
  world-readable, now and in the future. Current contents:
  `priv/frontend/{index.html,main.js,pcm-processor.js}` and
  `priv/assets/{tracks.json,mira_persona.txt,tracks/0[1-4]-song.mp3}`.
  Two consequences:
  1. `GET /assets/mira_persona.txt` publicly serves the persona text that
     `LiveDJ.Persona` bakes into the system instruction (`lib/live_dj/persona.ex:10-16`).
     System-prompt disclosure — it aids prompt-injection/jailbreak crafting against the
     Live session, and it is presumably licensed content copied from another project.
  2. Because `at: "/"` has no allow-list, any file later dropped into `priv/frontend`
     (a `.env` copy, a source map, an editor backup, a `notes.md`) is instantly public
     with no code change and no review signal.
- **Fix**:

  ```elixir
  plug(Plug.Static,
    at: "/assets",
    from: {:live_dj, "priv/assets"},
    only: ["tracks.json", "tracks"]
  )

  plug(Plug.Static,
    at: "/",
    from: {:live_dj, "priv/frontend"},
    index: ["index.html"],
    only: ~w(index.html main.js pcm-processor.js)
  )
  ```

  and move `mira_persona.txt` out of `priv/assets` into e.g. `priv/persona/` — it is
  read at compile time (`@external_resource`) and never needs to be web-served.

### 2.5 No security headers on any response

- **Severity**: Low
- **Location**: `lib/live_dj/router.ex` (no `put_secure_browser_headers` equivalent);
  `lib/live_dj/router.ex:33-35` serves `index.html` directly
- **Issue**: responses carry no `X-Content-Type-Options: nosniff`, no
  `X-Frame-Options`/`frame-ancestors`, no `Referrer-Policy`, no CSP. Impact is limited
  because the app renders no server-side HTML and has no cookies, but the page requests
  microphone access — without `X-Frame-Options: DENY` it can be framed by a hostile site
  for a clickjacking-assisted mic-permission prompt, and CSP would contain the damage of
  any future injection into `main.js`.
- **Fix**: a small plug ahead of `:match`:

  ```elixir
  plug(:secure_headers)

  defp secure_headers(conn, _opts) do
    put_resp_header(conn, "x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; connect-src 'self' ws: wss:; media-src 'self'; frame-ancestors 'none'"
    )
  end
  ```

  Note the current `index.html` uses an inline `<style>` block
  (`priv/frontend/index.html:7-44`), so a strict CSP needs `style-src 'self' 'unsafe-inline'`
  or the styles moved to a file.

---

## PRIORITY 3 — Input handling

### 3.1 Unvalidated client binary forwarded straight upstream

- **Severity**: Medium
- **Location**: `lib/live_dj/socket.ex:87-98`
- **Issue**: `handle_in({pcm, [opcode: :binary]}, ...)` passes the raw browser payload
  to `Audio.create_input_blob/1` with zero validation — no length check, no
  alignment check (s16le requires an even byte count), no rate accounting.
  `create_input_blob/1` (`deps/gemini_ex/lib/gemini/live/audio.ex:115-127`) only
  attaches a MIME type; it validates nothing. Combined with 2.1 this is the
  cost-amplification primitive: arbitrary attacker bytes, up to 1 MB per frame,
  unlimited frames, billed to the operator and attributed to the operator's Google
  account for content/abuse purposes.
- **Fix**: bound and shape-check at the boundary before forwarding.

  ```elixir
  @max_pcm_bytes 32_000  # ~1s of 16kHz s16le

  def handle_in({pcm, [opcode: :binary]}, %{session: session} = state)
      when session != nil and byte_size(pcm) <= @max_pcm_bytes do
    if rem(byte_size(pcm), 2) == 0 do
      # ... existing send_realtime_input, plus a per-socket byte budget in state
    else
      {:ok, state}
    end
  end

  def handle_in({_pcm, [opcode: :binary]}, state), do: {:stop, :normal, 1009, state}
  ```

### 3.2 `String.to_atom/1` in `LiveDJ.Tools.arg/2` — VERDICT: not attacker-controlled

- **Severity**: Low (latent footgun, not currently exploitable)
- **Location**: `lib/live_dj/tools.ex:77`
- **Verdict**: I traced every caller. `arg/2` is private and has exactly two call sites,
  `lib/live_dj/tools.ex:68` (`arg(args, "mood")`) and `:71` (`arg(args, "title")`).
  Both pass a **compile-time string literal**. The attacker/model-controlled value is
  `args` (the map) and `name` (the function name at `:66-75`), never `key`. The atom
  table therefore grows by at most two atoms, both of which already exist. **There is
  no atom-exhaustion DoS here.** Reporting it explicitly because the Iron Law demands a
  verdict either way.
- **Residual risk**: the shape is one refactor away from being a vulnerability — the
  moment someone writes `arg(args, some_key_from_the_model)` it becomes CWE-400. It is
  also unnecessary: the map is built by `Jason` decoding and has string keys, so the
  atom lookup is dead code in practice.
- **Fix**: delete the atom branch, or make it total:

  ```elixir
  defp arg(args, key) when is_map(args) do
    Map.get(args, key) || Map.get(args, safe_atom(key)) || ""
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
  ```

### 3.3 XSS via model-controlled output — VERDICT: no injection path found

- **Severity**: Informational (no finding)
- **Location**: `priv/frontend/main.js:21-26, 37, 38-45, 80-87`
- **Verdict**: I traced every model-controlled value that reaches the DOM. All sinks use
  `textContent`, never `innerHTML`/`insertAdjacentHTML`/`document.write`:
  - `addLine/2` (`:21-26`) builds the node with `createElement` and assigns
    `p.textContent` — transcript text (attacker-influenceable, since the attacker can
    speak into the session) is inert.
  - `setNow/1` (`:37`) uses `nowEl.textContent`, and its input comes from the
    server-owned `tracks.json`, not the model.
  - `setStatus/1` (`:20`) uses `textContent`, so even the leaked error string from 1.4
    cannot inject markup (`:86`).
  - `handlePlay/1` (`:38-45`) uses the model-controlled `cmd.value` only as an argument
    to `String.prototype.toLowerCase` and `Array.prototype.find` (`:41`) — it never
    reaches `music.src`. `music.src` is assigned only from `queue[i].file`
    (`:35, :43`), which originates from the server's own `tracks.json`.
  - `p.className = "line " + role` (`:23`) takes `role`, which the server constrains to
    the literals `"user"`/`"mira"` (`lib/live_dj/socket.ex:190-191`). Even an arbitrary
    string here can only add CSS classes, not markup.

  A hostile model output therefore cannot inject script. Worth keeping this property
  under test — it holds today only because every sink happens to be `textContent`.
- **Note (not XSS)**: `JSON.parse(evt.data)` at `:82` is unguarded; a malformed text
  frame throws inside `onmessage`. Server-controlled today, so cosmetic.

### 3.4 Model-controlled data can crash the socket process

- **Severity**: Low
- **Locations**:
  - `lib/live_dj/socket.ex:182` — `Audio.decode_output(b64)` calls `Base.decode64!/1`
    (`deps/gemini_ex/lib/gemini/live/audio.ex:153-155`), which raises `ArgumentError` on
    any non-strict base64 (including embedded whitespace). The library ships
    `decode_output_safe/1` returning `{:error, :invalid_base64}` and it is not used.
  - `lib/live_dj/socket.ex:190-191` — `transcript_role/1` has clauses only for `:input`
    and `:output`; any other role atom from the library raises `FunctionClauseError`.
  - `lib/live_dj/socket.ex:168` — `Enum.map` destructures `%{id: id, name: name}`;
    a function call missing `:id` raises inside the **session** process, and because
    `on_tool_call` runs there (`:66`), it takes the session down mid-conversation.
- **Issue**: each of these turns malformed upstream data into a dropped call. Not
  attacker-reachable directly, but it is the kind of crash a hostile-prompt-steered
  model can provoke, and `handle_tool_call/2` crashing inside the session defeats the
  `trap_exit` recovery the module was written for (`:42-44`).
- **Fix**: use `Audio.decode_output_safe/1` and skip on `:error`; add a catch-all
  `defp transcript_role(_), do: "mira"`; match `%{name: name} = call` and default the id
  with `Map.get(call, :id)`.

### 3.5 `String.to_integer/1` on `PORT`

- **Severity**: Low
- **Location**: `config/runtime.exs:47`
- **Issue**: a non-numeric `PORT` (trivially arriving via the unvalidated `.env` parser
  of 1.2) raises `ArgumentError` during `runtime.exs` evaluation, failing boot with a
  confusing error.
- **Fix**: `case Integer.parse(System.get_env("PORT") || "8000") do {p, ""} when p in 1..65_535 -> p; _ -> 8000 end`.

---

## Recommendations (priority order)

1. **Rotate the Gemini API key in `.env`** — it has been read by tooling. Then confirm
   `git log --all -- .env` is empty (expected: it is) and add a `.dockerignore`.
2. **Authenticate `/ws`** (2.1). Nothing else matters while any host on the network can
   spend the operator's Gemini budget. Short-TTL signed ticket + reverse proxy.
3. **Stop echoing `inspect(reason)` to the browser** (1.4). One-line fix, removes both
   the confirmed internals oracle and the latent credential path.
4. **Add an Origin check** (2.2) and **connection/rate/frame caps** (2.3).
5. **Allow-list the `Plug.Static` mounts** and move `mira_persona.txt` out of the
   web-served directory (2.4).
6. **Allow-list keys in the dotenv parser**, or skip the file entirely in `:prod` (1.2).
7. **Install a Logger filter that redacts `key=`** and disable SASL reports (1.5).
8. Bound and shape-check client PCM in `handle_in/2` (3.1); harden the model-data crash
   paths (3.4); drop the `String.to_atom/1` branch (3.2).

## Tools the user should run (no Bash access here)

- `git check-ignore -v .env ; git ls-files --error-unmatch .env ; git log --all --oneline -- .env`
  — confirms the 1.1 verdict.
- `mix deps.audit` and `mix hex.audit` — retired/vulnerable dependency check.
- `mix xref graph --format cycles` — not security, but useful before refactoring.
- `sobelow` is **not applicable** (Phoenix-only) and should not be run.
