defmodule LiveCeci.Limits do
  @moduledoc """
  Every ceiling in the app, in one place, because they constrain each other.

  Six numbers. Read separately — one in `LiveCeci.Tickets`, one in `LiveCeci.Sessions`,
  the rest in `config/runtime.exs` — each looks like an independent knob, and the
  relationship between them is something you discover by measuring a failure. It was:
  raising `MAX_TICKETS_PER_ADDRESS` without raising the global bound turned the eviction
  that protects the table into something that threw away tickets seconds after issuing
  them.

  So they live together and the derived one is derived here. If you add a seventh, add it
  here — an audit caught this moduledoc claiming "four" after two more had been added,
  which is precisely the drift the module exists to prevent, in the module that exists to
  prevent it.

  ## How they relate

    * `tickets_outstanding/0` is `tickets_per_address/0` doubled, and is the only one that
      is derived rather than configured.
    * `session_lifetime_ms/0` and `session_byte_budget/0` are two spellings of one bound,
      and the byte budget must stay the LOOSER of the two for ordinary speech — otherwise
      the clock, which is the one that catches a forgotten tab, would never be what fired.
      `limits_test.exs` asserts that.
    * `sessions_total/0` and `sessions_per_address/0` coincide on loopback, where every
      address is 127.0.0.1, and stop coinciding the moment `BIND_IP` opens.

  ## The chain a connection walks

      POST /ws-ticket   ->  tickets_per_address/0    how many upgrades one address may
                            tickets_outstanding/0    have in flight at once, and in total
      GET  /ws          ->  sessions_per_address/0   how many live sessions one address
                            sessions_total/0         how many live sessions in total
      while it lives    ->  session_lifetime_ms/0    how long one may last, and how much
                            session_byte_budget/0    microphone it may spend

  Tickets are the outer ring and are deliberately far looser: a ticket costs 60 bytes
  for 30 seconds, a session costs an upstream connection that is billed for as long as
  it lives. Refusing a ticket is not a defence worth having — refusing a session is.

  ## What "per address" means depends on the deployment

  On loopback it is one person. Behind a NAT or a reverse proxy it is EVERYONE, and
  then `sessions_per_address/0` — not `sessions_total/0` — is the ceiling on concurrent
  users. `LiveCeci.Router` restores the real client address from `X-Forwarded-For` when
  the peer is a configured trusted proxy, which is what keeps that from happening
  silently.
  """

  @doc "How many live sessions may exist at once, across every address."
  @spec sessions_total() :: pos_integer()
  def sessions_total, do: Application.get_env(:live_ceci, :max_sessions, 8)

  @doc "How many live sessions one address may hold."
  @spec sessions_per_address() :: pos_integer()
  def sessions_per_address, do: Application.get_env(:live_ceci, :max_sessions_per_address, 4)

  @doc "How many unspent upgrade tickets one address may hold at once."
  @spec tickets_per_address() :: pos_integer()
  def tickets_per_address, do: Application.get_env(:live_ceci, :max_tickets_per_address, 150)

  # Two, so the headroom scales with whatever the per-address cap is set to, and the two
  # cannot be raised out of step — which is the drift this module exists to prevent.
  @outstanding_ratio 2

  @doc """
  The global bound on outstanding tickets. DERIVED, never configured.

  With fair-share eviction in `LiveCeci.Tickets`, this also fixes what each address gets
  when the table is full: `tickets_outstanding/0` divided by the number of busy
  addresses. At the default that is 300, so three simultaneously-flooding addresses
  settle at 100 tickets each — still two orders of magnitude more than a browser needs.
  """
  @spec tickets_outstanding() :: pos_integer()
  def tickets_outstanding, do: tickets_per_address() * @outstanding_ratio

  @doc """
  How long one session may live, in milliseconds, regardless of activity.

  Bandit's `:timeout` is an IDLE timeout — `{:persistent, timeout}` resets on every
  frame read — and an open microphone sends ten frames a second, so it never fires.
  Nothing else bounded a session: a forgotten tab held an upstream session that is
  billed by the minute, for as long as the laptop stayed awake.
  """
  @spec session_lifetime_ms() :: pos_integer()
  def session_lifetime_ms, do: Application.get_env(:live_ceci, :max_session_ms, 900_000)

  @doc """
  How many bytes of microphone audio one session may send before it is closed.

  The other half of the same bound, for the case the clock does not catch: 16 kHz s16le
  is 32 kB/s, so the default 100 MB is about 52 minutes of continuous speech — well
  past `session_lifetime_ms/0`, and there to catch a client sending faster than real
  time, which the clock alone would not.
  """
  @spec session_byte_budget() :: pos_integer()
  def session_byte_budget, do: Application.get_env(:live_ceci, :max_session_bytes, 100_000_000)
end
