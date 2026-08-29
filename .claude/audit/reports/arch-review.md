# Architecture Review — live-ceci (OTP app, not Phoenix)

Scope: module boundaries, OTP process design, coupling, duplicated concepts, naming.
`mix xref graph --format stats`: 14 nodes, 24 runtime edges, 0 compile/exports edges,
0 cycles. `mix xref graph --format cycles`: none. Evaluated as plain OTP, not against
Phoenix conventions.

## P2

### 1. `LiveCeci.Limits` and its test both undercount the ceilings they own
`lib/live_ceci/limits.ex:3-4`:
> "There are four numbers here and three of them are related."

The module now exports six: `sessions_total/0`, `sessions_per_address/0`,
`tickets_per_address/0`, `tickets_outstanding/0` (derived), `session_lifetime_ms/0`,
`session_byte_budget/0`. The same stale count is repeated verbatim in
`test/live_ceci/limits_test.exs:3` ("The four ceilings, and the one relationship
between them that is not a knob."). This is the one place in the codebase whose whole
job is being the inventory of ceilings, and the inventory is wrong by two — exactly the
kind of drift the module's own moduledoc warns about happening when the numbers live
apart. A reader counting the four described numbers to check they've found them all
will stop before reaching `session_lifetime_ms/0` and `session_byte_budget/0`.

**Consequence**: the next person adding or auditing a ceiling trusts the doc's count,
not the source, and undercounts what has to be reasoned about together.

### 2. `LiveCeci.Sessions` and `LiveCeci.LiveSession` are one edit-distance apart and describe different things
`lib/live_ceci/sessions.ex:1` is the process-count cap shared by every browser
connection. `lib/live_ceci/live_session.ex:1` is a per-connection audio carrier that
exists for exactly one provider (Gemini — see `provider/gemini.ex:59`); Grok has no
equivalent module because `WebSockex` already gives it an independent process.
Grepping, aliasing, or skimming module names for "session" turns up both, and the
plural/singular distinction is the only signal that they are unrelated: one is a
capacity gate for the whole app, the other is a backpressure buffer for one provider's
audio path. A third provider arriving (the scenario `LiveCeci.Provider`'s own moduledoc
anticipates at `provider.ex:106`) has no naming cue that it might need something shaped
like `LiveSession` and would not find it by searching for "Gemini".

**Consequence**: a reader tracing "how many sessions can exist" vs. "how does audio get
to the provider without blocking the socket" has to open both files to learn they don't
answer the same question, and a name search for the audio carrier concept doesn't
surface it from the provider side.

## P3

### 3. `LiveCeci.Socket.terminate/2` has an unreachable fallback clause
`lib/live_ceci/socket.ex:222` and `:228`:
```elixir
def terminate(reason, %{session: session, provider: provider}) do
  ...
end

def terminate(_reason, _state), do: :ok
```
Every state map this module ever constructs — `refuse/0` (line 73), the two branches of
`open_session/0` (lines 106 and 113), and every `handle_info`/`handle_in` clause that
returns a modified state — carries both `:session` and `:provider` keys. The first
clause therefore matches every state `WebSock` can ever pass to `terminate/2`, and the
second clause can never run. It reads as a defensive fallback, which invites a future
edit to rely on it actually being reachable (e.g. "the fallback already handles a state
without those keys").

**Consequence**: a reader auditing what happens when `terminate/2` gets an unexpected
shape will conclude there's a safety net where there isn't one.

## Not flagged

- `provider/grok.ex` size and single-module structure: the moduledoc's argument (one
  wire protocol without a client library is the unit that has to stay consistent) holds
  up against the file as read — `session_update/1` and `translate/2` are the only two
  seams, and neither is reused or reusable independently of the other's context. No
  counter-argument found.
- The duplicated `LiveCeci.Sessions.available?/1` check in `router.ex:252` alongside
  `join/1` in `socket.ex:62` is already documented as deliberate at the call site
  (router.ex:247-251), with the cost measured; not re-flagged.
- No `mix xref` cycles; the Provider/Grok/Gemini cycle avoided by reading `current/0`
  from config rather than naming an implementation is holding.
