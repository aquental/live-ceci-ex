# Security Audit: live_ceci

Scope: `lib/`, `config/`, `priv/frontend/`. Threat model taken as given — availability and
API-key spend are the assets; no accounts, no cookies, no DB.

Four findings. Everything else in the checklist (SQL, XSS, CSRF, atom exhaustion, path
traversal, secrets in code, log redaction, security headers, CSP host handling) was checked
and is clean — see "Checked and clean" at the bottom for what that means concretely.

---

## P1 — `end_of_speech` is unmetered: unbounded billed `response.create` on the default provider

- **Severity**: High (cost + upstream availability)
- **Location**: `lib/live_ceci/socket.ex:141-149`, `lib/live_ceci/provider/grok.ex:151-160`,
  `lib/live_ceci/socket.ex:235-247`
- **Verified**: by reading source. Not executed, not load-tested. The local code path is
  certain; the size of the upstream bill is inferred from OpenAI-Realtime semantics for
  `response.create`, which `Grok`'s own moduledoc says the protocol is.

### Issue

Both new bounds in `LiveCeci.Limits` are on the *binary* path only:

- `spent/2` (`socket.ex:235`) is called from exactly one place — the `opcode: :binary`
  clause at `socket.ex:120`. The `opcode: :text` clause at `socket.ex:141` returns
  `{:ok, state}` without touching `state.bytes`, so text frames are charged against
  `session_byte_budget/0` at a rate of zero.
- `session_lifetime_ms/0` is a 15-minute wall clock. It bounds duration, not rate.

So the only rate limit on a text frame is the TCP link. And the text frame is not inert:

```elixir
case Jason.decode(data) do
  {:ok, %{"type" => "end_of_speech"}} -> provider.commit_turn(session)
```

`Grok.commit_turn/1` then issues two casts per call:

```elixir
WebSockex.cast(ws, {:send, %{type: "input_audio_buffer.commit"}})
WebSockex.cast(ws, {:send, %{type: "response.create"}})
```

`response.create` is an explicit request for the model to generate — the billed unit.
Grok is the default provider (`config/config.exs:8`). Gemini's `commit_turn/1` is a no-op
(`gemini.ex:139`), so this is the default path and only the default path.

Two aggravating details:

1. `commit_turn/1` has **no `backed_up?/1` guard**, unlike `send_audio/2` at
   `grok.ex:131`. The comment at `grok.ex:120-130` describes exactly the failure this
   reintroduces — `WebSockex.cast/2` never blocks, so 5000 casts at a process draining at
   WAN speed produce a 5000-message mailbox and `:ok` every time. `send_audio/2` was
   fixed; `commit_turn/1` was not.
2. Each commit turns the buffered audio into a conversation item. Repeated commits grow
   the context that is re-sent on every subsequent turn, so the token cost is worse than
   linear in the number of frames sent.

### Failure scenario

A client that holds one session — which costs one `POST /ws-ticket` and one `GET /ws`;
the `Origin` check is satisfied by any non-browser sending `Origin: http://localhost`,
which `Tickets`' moduledoc already concedes — writes `{"type":"end_of_speech"}` in a loop.
Nothing in the app counts it, nothing drops it, nothing closes the socket early. The
session runs its full 15 minutes issuing generation requests as fast as the upstream
socket accepts frames. Eight concurrent sessions can do it at once. A buggy frontend
(a `workletNode.port.onmessage` firing `endOfSpeech` on every batch — `main.js:193` sends
it unconditionally) produces the same bill by accident.

### Fix

Two independent changes; do both.

```elixir
# lib/live_ceci/socket.ex — charge text frames, and rate-limit the turn.
@commit_min_interval_ms 250

def handle_in({data, [opcode: :text]}, %{session: session, provider: provider} = state)
    when session != nil do
  with {:ok, state} <- spent(state, byte_size(data)),
       {:ok, %{"type" => "end_of_speech"}} <- Jason.decode(data),
       true <- commit_allowed?(state) do
    provider.commit_turn(session)
    {:ok, %{state | last_commit_at: System.monotonic_time(:millisecond)}}
  else
    {:stop, _, _, _, _} = stop -> stop
    _ -> {:ok, state}
  end
end
```

(`spent/2` currently returns `{:ok, state} | {:stop, ...}`; keep that shape and let the
stop tuple fall straight through. `last_commit_at` initialises to `0` in all three state
literals — `socket.ex:73`, `:106`, `:113`.)

```elixir
# lib/live_ceci/provider/grok.ex — the guard send_audio/2 already has.
def commit_turn(ws) do
  unless backed_up?(ws) do
    WebSockex.cast(ws, {:send, %{type: "input_audio_buffer.commit"}})
    WebSockex.cast(ws, {:send, %{type: "response.create"}})
  end
  :ok
catch
  :exit, _reason -> :ok
end
```

A human turn ends a few times a minute. 250 ms is four orders of magnitude of headroom
and costs the legitimate client nothing.

**OWASP**: API4:2023 Unrestricted Resource Consumption.

---

## P2 — `/ws` reaches the serialised `Sessions` singleton before the ticket is checked

- **Severity**: Medium (availability)
- **Location**: `lib/live_ceci/router.ex:252` vs `:256`; `lib/live_ceci/sessions.ex:55-62`
- **Verified**: by reading source. The ordering and the fail-closed behaviour are certain;
  the request rate needed to trigger it is reasoned, not measured.

### Issue

In the `cond` at `router.ex:238`:

```
238  not origin_allowed?(origin)          -> 403     # pure function
252  not LiveCeci.Sessions.available?(..) -> 503     # GenServer.call, serialised singleton
256  not ticket_ok?(conn)                 -> 403     # ETS lookup
```

The authorisation step is last. Every unauthenticated `GET /ws` — no ticket, none ever
minted — costs one `GenServer.call` on the one process that every legitimate upgrade must
also queue behind.

`join/1` **fails closed** by design (`sessions.ex:55-62`: a 1 s timeout, `catch :exit ->
{:error, :too_many_sessions}`), and that is the right call in isolation. But combined with
the ordering it becomes an amplifier: an attacker who never obtains a ticket can push the
`Sessions` mailbox past one second of work, at which point *ticket-holding* clients get
`{:error, :too_many_sessions}` and a 1013 close while every slot is free. That is precisely
the failure the `Sessions` moduledoc says serialisation exists to prevent ("Refusing while
slots are free is an outage"), arriving through the router instead of through the count.

The moduledoc at `router.ex:245-251` defends the *duplication* of the `Sessions` call. It
does not address the *ordering* relative to the ticket check, and the two are separable.

### Why the obvious fix is wrong

Simply moving `available?` below `ticket_ok?` burns the ticket on a capacity refusal —
exactly what `router.ex:245-251` and `sessions.ex:64-76` exist to avoid. `consume/2` is
destructive by design, so the check cannot be reordered as-is.

### Fix

Add a non-destructive peek to `LiveCeci.Tickets` — same match spec as `consume/2`, counting
instead of deleting — and gate on it first:

```elixir
# lib/live_ceci/tickets.ex
@spec valid?(String.t() | nil, :inet.ip_address()) :: boolean()
def valid?(ticket, address) when is_binary(ticket) do
  spec = [{{ticket, :"$1", address}, [{:<, {:const, now()}, :"$1"}], [true]}]
  :ets.select_count(@table, spec) == 1
end

def valid?(_ticket, _address), do: false
```

```elixir
# lib/live_ceci/router.ex — authorise, then check capacity, then spend.
not origin_allowed?(origin)                                    -> 403
not LiveCeci.Tickets.valid?(conn.query_params["ticket"], ip)   -> 403
not LiveCeci.Sessions.available?(conn.remote_ip)               -> 503   # ticket still unspent
not ticket_ok?(conn)                                           -> 403   # lost the race, rare
true                                                           -> upgrade
```

The peek is the same hash lookup as `consume/2` (bound key on a `set`), so the added cost
is ~1 µs and the unauthenticated path never touches the singleton. The TOCTOU between
`valid?` and `consume` is benign — `consume/2` remains the authoritative single-use gate,
and losing the race yields the same 403 as today.

**OWASP**: API4:2023 Unrestricted Resource Consumption.

---

## P3 — Global ticket bound degrades to random eviction under a many-address flood

- **Severity**: Low today (loopback default), Medium if `BIND_IP` opens
- **Location**: `lib/live_ceci/tickets.ex:101`, `:128-144`; `lib/live_ceci/limits.ex:48-59`
- **Verified**: by reading source plus reasoning about the eviction rule. Not measured.
  I am *not* disputing the measurement in the moduledoc — it is correct for the case it
  covers. This is a different case.

### Issue

`evict_from_largest/0` selects `Enum.max_by(fn {_addr, {count, _, _}} -> count end)`. The
max-min fairness argument in the moduledoc holds when the flooder *concentrates*: three
addresses at 150/121/29 converge to 100 each, and a legitimate holder of one ticket is
never the maximum.

It stops holding when every bucket has size 1. `tickets_outstanding/0` is
`tickets_per_address() * 2` = **300** at the default (`limits.ex:48,59`). Fill the table
from 300 distinct addresses holding one ticket each, and every address is tied at 1;
`max_by` returns whichever the `foldl` reached first, which is arbitrary. Eviction never
refuses (`tickets.ex:101` — `if ... do: evict_from_largest()`, then insert unconditionally),
so the flooder always gets its slot, and each flooder mint destroys one arbitrary ticket
out of 300.

### Failure scenario

`BIND_IP` is opened and the service is reachable. An attacker with an IPv6 /64 — or a
modest botnet — mints from ~300 source addresses. A legitimate browser does
`POST /ws-ticket` then `GET /ws`; the gap is one round trip, call it 200 ms. At 3000
attacker mints/sec the survival probability of that one ticket is `(299/300)^600 ≈ 0.14`.
The user gets a 403 from `consume/2` on ~86% of attempts, and `main.js` shows
"não consegui autorizar a conexão". The per-address cap — the bound the moduledoc says is
"the bound that actually stops the flood" — never fires, because no single address exceeds
1.

### Fix

Two options; the first is a one-line config change and is probably enough.

1. Stop deriving the global bound from the per-address bound. It is a *memory* budget —
   a row is ~60 bytes, so 50 000 tickets is ~3 MB — and coupling it to a per-address cap
   of 150 is what makes it small enough to fill with a botnet:

   ```elixir
   # lib/live_ceci/limits.ex
   @doc "Global memory backstop on outstanding tickets. Not derived from the per-address cap."
   def tickets_outstanding, do: max(tickets_per_address() * 2, 50_000)
   ```

   Note this partly reverses the coupling that `Limits` exists to enforce; the `max/2`
   keeps the invariant `tickets_outstanding >= 2 * tickets_per_address` that the module
   was created to protect.

2. Refuse rather than evict when the largest holder holds only one ticket. At that point
   no address is abusing the table, and destroying an incumbent's only ticket is strictly
   worse than refusing the newcomer:

   ```elixir
   defp evict_from_largest do
     (&tally/2)
     |> :ets.foldl(%{}, @table)
     |> Enum.max_by(fn {_a, {count, _t, _e}} -> count end, fn -> nil end)
     |> case do
       {_a, {count, ticket, _e}} when count > 1 -> :ets.delete(@table, ticket); :ok
       _ -> :refused
     end
   end
   ```

   with `issue/1` returning `{:error, :too_many}` on `:refused`. This costs the documented
   "eviction never refuses" property, so take option 1 if that property is load-bearing.

---

## P3 — `TRUSTED_PROXIES` silently never matches an IPv4-mapped peer

- **Severity**: Low (fails closed, but silently reverts the defence it was added for)
- **Location**: `lib/live_ceci/router.ex:100`, `config/runtime.exs:150-165`
- **Verified**: by reading source. `:inet.parse_address('10.0.0.1')` returning `{10,0,0,1}`
  and a dual-stack `AF_INET6` accept yielding `{0,0,0,0,0,65535,a,b}` are standard
  `:inet` behaviour; I did not execute this.

### Issue

`client_address/2` gates on `conn.remote_ip in trusted` — exact tuple equality.
`TRUSTED_PROXIES` entries are parsed with `:inet.parse_address/1`, so `10.0.0.1` becomes
the 4-tuple `{10,0,0,1}`. If the listener is opened on `BIND_IP=::` (the normal way to
accept both families), the kernel reports an IPv4 peer as the IPv4-mapped 8-tuple
`{0,0,0,0,0,65535,2560,1}`. `{0,0,0,0,0,65535,2560,1} in [{10,0,0,1}]` is `false`.

The plug then does nothing, silently. There is no log, no boot-time warning, and the 503/403
counters look normal. The deployment reverts to exactly the three failures
`router.ex:80-91` documents: the ticket's address binding becomes a tautology,
`MAX_SESSIONS_PER_ADDRESS` becomes a global cap of 4 concurrent users for the whole
deployment, and every rejection log names the proxy.

This fails *closed* — `X-Forwarded-For` is ignored rather than trusted, so there is no
spoofing window. The cost is availability and the loss of a defence the operator believes
is on.

### Fix

Normalise both sides before comparing:

```elixir
# lib/live_ceci/router.ex
defp normalise({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
  do: {Bitwise.bsr(ab, 8), Bitwise.band(ab, 0xFF), Bitwise.bsr(cd, 8), Bitwise.band(cd, 0xFF)}

defp normalise(address), do: address
```

and use `normalise(conn.remote_ip) in trusted` at `router.ex:100`, plus `normalise/1` on
each parsed address in `client_address/2`. Apply the same normalisation to the address that
reaches `Tickets` and `Sessions`, otherwise the same client can be counted under two
identities depending on which family it connected with.

Cheaper alternative if dual-stack is out of scope: warn at boot when `TRUSTED_PROXIES` is
non-empty and `bind_ip` is an 8-tuple, since the two are almost certainly inconsistent.

---

## Checked and clean

Reported here only so it is on record what was looked at and dismissed.

- **Injection**: no Ecto, no SQL, no `String.to_atom/1` on any input path. `Tools.arg/2`
  (`tools.ex:202`) deliberately takes the atom and derives the string, with the reasoning
  written down. `String.to_existing_atom` is not needed anywhere.
- **XSS**: `priv/frontend/main.js` uses `textContent` at every sink — `addLine`
  (`:36`), `handleAction` (`:57`), `setStatus` (`:28`). No `innerHTML`, no
  `insertAdjacentHTML`, no `eval`. Model-controlled transcript and tool `detail` text is
  therefore inert even before CSP.
- **CSP**: `@host_chars` (`router.ex:66`) excludes `;`, `,`, whitespace, quotes and `*`, so
  the attacker-controlled `Host` cannot terminate a directive, split the policy, or inject
  a source expression. Malformed hosts fall back to `'self'` alone. The four-way
  `connect-src` pinning is sound. IPv6 literal hosts fail the regex and fall back to
  `'self'`, which is correct behaviour, not a hole.
- **Origin check**: `userinfo: nil` closes `http://evil@localhost`. The `{scheme, host, port}`
  triple is compared with both sides downcased and both sides run through `URI.parse`, so
  default-port and case variants match. `Origin: null` (sandboxed iframe) parses to
  `scheme: nil` and is rejected. A config entry that is not a valid absolute URI keys to
  `:invalid` and can never match a real origin — fails closed.
- **Ticket match specs**: `consume/2` (`tickets.ex:170`) is correct. The address tuple sits
  in the match *head*, where a literal tuple is a structural pattern and needs no `{const, _}`
  escaping; the `now()` comparison in the *guard* is correctly escaped as `{:const, now()}`.
  The key is bound literally on a `:set`, so it is a hash lookup. The atomicity claim holds —
  a row whose address does not match is never touched.
- **`X-Forwarded-For` walk**: right-to-left with `drop_while(&(&1 in trusted))` and a hard
  stop on an unparseable entry is the correct algorithm. Ignoring the header entirely while
  `TRUSTED_PROXIES` is empty is the correct default. (The only defect is the tuple-family
  mismatch above.)
- **Secrets**: nothing hardcoded outside `config/test.exs:6` (`"test-key"`, deliberate).
  `runtime.exs:38-49` skips key loading entirely in `:test`. `Redact.secrets/0` reads
  `GROK_API_KEY` at call time, and the dotenv loader `System.put_env`s it, so the default
  provider's key *is* covered by the known-value pass. `binaries: :as_strings` is correct
  and necessary. Longest-first ordering prevents prefix leakage.
- **`Process.flag(:sensitive, true)`** in `Grok.handle_connect/2` is set after the socket
  is up, so it does not cover a crash during connection establishment — but WebSockex's
  `open_connection` failure path (`deps/websockex/lib/websockex.ex:612-622`) returns
  `{:error, reason}` to the caller rather than raising with the `%WebSockex.Conn{}` in the
  reason, and `:proc_lib` crash reports do not include a non-`gen_server` loop state. The
  `KNOWN LEAK` note at `grok.ex:73-79` is accurate and the residual window does not widen it.
- **`handle_disconnect/2` returning `{:ok, state}`** does *not* reconnect — confirmed at
  `deps/websockex/lib/websockex.ex:1168-1176`, where only `{:reconnect, _}` triggers
  `open_connection`. No hidden reconnect loop, no hidden billing.
- **Upstream session leaks**: both `Grok.open/1` (`:96`) and `Gemini.connect_or_close/1`
  (`gemini.ex:55-73`) close the upstream before returning an error, and
  `Sessions.close_upstream/1` is a monitor-driven backstop. The `attach/2` cast leaves a
  sub-millisecond window where a hard kill between `provider.open` success and `attach`
  would orphan an upstream session; too narrow to be worth restructuring for.
- **Tools input validation**: `coerce/2` handles non-string model output, bounds work with
  `binary_part` before `String.slice`, and `whole_graphemes/1` repairs a mid-codepoint cut.
  `complete/2` refuses to emit an action with a missing required field.
- **Path traversal**: the only `File`/`send_file` call is `router.ex:301`, a fixed literal
  path. `Plug.Static` handles its own traversal defence. `priv/assets` is deliberately not
  routed.
- **CSRF**: no cookies and no ambient authority, so there is nothing for a forged request to
  ride. The `Origin` check on `POST /ws-ticket` (`router.ex:213-214`) is the correct
  substitute.

## Tools to run manually

This agent has no shell. Worth running:

- `mix sobelow --exit medium --skip` (expect Config.HTTPS and a `send_file` false positive)
- `mix deps.audit` / `mix hex.audit`
- `mix compile --warnings-as-errors && mix format --check-formatted` after any fix above
