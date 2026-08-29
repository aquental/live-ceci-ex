defmodule LiveCeci.Tickets do
  @moduledoc """
  Short-lived, single-use tickets that authorise one `/ws` upgrade.

  ## Why the upgrade cannot authenticate itself

  The browser's `new WebSocket(url)` takes no headers. There is no place to put a bearer
  token, and cookies do not travel reliably across origins. So the authentication does
  not happen at the upgrade — it happens just before it, over ordinary HTTP where the
  whole apparatus works, and the upgrade only presents the proof.

      POST /ws-ticket   ->  {"ticket": "..."}      an ordinary HTTP request
      GET  /ws?ticket=...                          the upgrade shows what it was given

  ## The three properties, and what each is for

    * **Single use.** The ticket rides in a query string, and query strings leak — proxy
      logs, browser history, `Referer`. `:ets.take/2` makes consumption atomic, so a
      leaked ticket is already spent. This is the one that matters most.
    * **Short lived.** #{div(30_000, 1000)} seconds. It shortens the window between
      leaking and being used; it does not close it, which is what single use is for.
    * **Bound to the client address.** A ticket minted for one host cannot be presented
      from another. On loopback that is nearly free; it starts mattering the moment
      `BIND_IP` opens up, which is exactly when nobody remembers to add it.

  ## What this does NOT buy, today

  There are no user accounts here, so a ticket proves that whoever is upgrading first
  made an HTTP request from the same address — not who they are. Against a browser on
  another site it is decisive, together with the `Origin` check. Against something
  talking HTTP directly on this machine it is two requests instead of one.

  Its real value now is that it is the seam. When there is an identity to check, it is
  checked in `issue/1` and everything downstream already carries the consequence.

  ## The bound, and the two denials of service it used to be

  `LiveCeci.Limits.tickets_outstanding/0` stops an unauthenticated endpoint growing a
  table without end. Getting that bound to behave took two corrections, and both were
  measured rather than reasoned:

    * **It refused the newest request.** 200 mints from one address filled the table and
      every other user got `{:error, :too_many}` — a memory bound turned into an
      availability weapon. Fixed by capping per address, so filling the table from one
      place is no longer possible, and by evicting rather than refusing.

    * **It evicted the globally oldest.** Which is the same weapon pointed at whoever
      arrived FIRST. Measured at the default cap with three busy addresses: the first
      address kept **29** of its 150 tickets, the second 121, the third all 150 — the
      newcomer takes everything and the incumbent starves. `evict_from_largest/0` takes
      the oldest ticket from whichever address holds the MOST instead, which is max-min
      fairness: the same three addresses settle at 100 each.

  Eviction never refuses, so a mint always succeeds once past the per-address cap. That
  is deliberate — the per-address cap is the bound that means something, and the global
  one is a backstop on memory.
  """

  use GenServer

  require Logger

  @table __MODULE__
  # Separate from the ticket table so a sweep cannot delete the counter.
  @counters Module.concat(__MODULE__, Counters)
  @ttl_ms 30_000
  @sweep_every_ms 60_000

  # 32 bytes. Long enough that guessing is not a strategy, short enough for a URL.
  @bytes 32

  # ---------------------------------------------------------------- client

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Mints a ticket for `address`, or refuses if too many are outstanding.
  """
  @spec issue(:inet.ip_address()) :: {:ok, String.t()} | {:error, :too_many}
  def issue(address) do
    maybe_sweep()

    cond do
      count_for(address) >= max_per_address() ->
        # The bound that actually stops the flood, because it is scoped to whoever is
        # flooding. Refusing here denies one address, not everyone.
        #
        # A counter, not a log line. issue/1 runs in the CONNECTION process, so a refusal
        # that logs puts the logging backend on the upgrade path: measured at 5 µs with
        # the default handler and 3001 µs with a 2 ms sink standing in for a network file
        # or a remote syslog. Same shape, same fix, and the same reasoning as
        # LiveCeci.Sessions — the rate is reported by the sweep timer, off any caller.
        :ets.update_counter(@counters, :refused, 1, {:refused, 0})
        {:error, :too_many}

      true ->
        # Global backstop on memory. It evicts rather than refuses, and it evicts from
        # whichever address holds the most rather than whichever ticket is oldest — the
        # two together are what stop this bound being usable as a weapon in either
        # direction. See the moduledoc for the measurements behind both.
        if :ets.info(@table, :size) >= max_outstanding(), do: evict_from_largest()

        ticket = @bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        :ets.insert(@table, {ticket, now() + @ttl_ms, address})
        {:ok, ticket}
    end
  end

  # A browser needs one ticket per connection, and a ticket that is minted but never
  # presented still occupies a slot for its full TTL — a failed connect, a closed tab
  # between the fetch and the upgrade. The cap and the global bound derived from it both
  # live in LiveCeci.Limits, with the other three ceilings they constrain.
  defp max_per_address, do: LiveCeci.Limits.tickets_per_address()
  defp max_outstanding, do: LiveCeci.Limits.tickets_outstanding()

  defp count_for(address) do
    :ets.select_count(@table, [{{:_, :_, :"$1"}, [{:==, :"$1", {:const, address}}], [true]}])
  end

  # Fair-share, not oldest-first. Whichever address holds the most tickets loses its
  # oldest one; ties go to whoever the fold reached first, which is arbitrary and fine.
  # One pass over a table that is 300 rows at the default, on a path that only runs when
  # the table is already full.
  #
  # The property this buys: repeated eviction drives the distribution towards equal
  # shares, so no address can be starved by one that arrived later. Oldest-first had the
  # opposite property, measured — see the moduledoc.
  defp evict_from_largest do
    counts = :ets.foldl(&tally/2, %{}, @table)

    # Ties break on the oldest ticket, not on map order. With 300 addresses holding one
    # ticket each every bucket ties at 1, and `max_by` on the count alone would then pick
    # by internal hash order — which is arbitrary AND stable, so the same unlucky address
    # would be evicted every time. Breaking on expiry turns that case into "drop whatever
    # is closest to expiring", which is the right answer there and costs nothing: the fold
    # already tracks the oldest per address.
    case Enum.max_by(counts, fn {_address, {count, _t, exp}} -> {count, -exp} end, fn -> nil end) do
      {_address, {_count, ticket, _expires}} -> :ets.delete(@table, ticket)
      nil -> :ok
    end
  end

  defp tally({ticket, expires, address}, acc) do
    Map.update(acc, address, {1, ticket, expires}, fn {count, best, best_exp} ->
      if expires < best_exp,
        do: {count + 1, ticket, expires},
        else: {count + 1, best, best_exp}
    end)
  end

  @doc """
  Whether a ticket would be accepted, WITHOUT spending it.

  The router asks this before it asks `LiveCeci.Sessions`, so an unauthenticated request
  never reaches the one process every legitimate upgrade queues behind. That ordering was
  the other way round and a security audit caught it: the `Origin` check is trivial to
  satisfy from anything that is not a browser, so a flood of forged upgrades could sit in
  front of the capacity singleton — and `join/1` fails CLOSED, so the flood would have
  become "muitas conexões" while every slot was free.

  It is advisory, like `LiveCeci.Sessions.available?/1` and for the same reason: the
  ticket can be spent by a racing connection between this answer and `consume/2`. That is
  fine, because `consume/2` remains the authoritative check and still refuses.
  """
  @spec valid?(String.t() | nil, :inet.ip_address()) :: boolean()
  def valid?(ticket, address) when is_binary(ticket) do
    :ets.select_count(@table, match_spec(ticket, address)) == 1
  end

  def valid?(_ticket, _address), do: false

  @doc """
  Spends a ticket. Succeeds at most once per ticket, and only from the address it was
  minted for.

  A wrong, expired, replayed or absent ticket is the same answer on purpose: telling
  them apart tells a caller which half of a guess was right.
  """
  @spec consume(String.t() | nil, :inet.ip_address()) :: :ok | {:error, :invalid}
  def consume(ticket, address) when is_binary(ticket) do
    # One atomic operation that checks all three properties at once, because splitting
    # them was a bug. `:ets.take/2` used to remove the row and match the address
    # AFTERWARDS, so presenting a stolen ticket from the wrong address destroyed it:
    # reproduced, and the legitimate owner's next attempt answered {:error, :invalid}.
    # Whoever leaked the ticket could not use it, but could deny it.
    #
    # A match spec puts the address in the PATTERN, so a row that does not match is
    # never touched. The ticket is the key and is bound literally, so ETS still resolves
    # it by hash rather than scanning: measured at 0.50 µs per call over a 300-row table
    # and 0.41 µs over a 3000-row one — flat, which is what proves it is not a scan. The
    # `take` it replaces costs 0.12 µs, so this is 0.38 µs more, once per connection,
    # against a handshake that spends hundreds of milliseconds opening the upstream.
    #
    # No `when expires_at > 0` anywhere near this, however natural it looks.
    # System.monotonic_time/1 has an arbitrary origin and is deeply negative on this
    # machine — measured at -576460751723 — so that guard rejected every valid ticket.
    # The guard below compares against `now` and holds whatever the origin is.
    case :ets.select_delete(@table, match_spec(ticket, address)) do
      1 -> :ok
      0 -> {:error, :invalid}
    end
  end

  def consume(_ticket, _address), do: {:error, :invalid}

  # Shared by valid?/2 and consume/2 so the two can never disagree about what a good
  # ticket is — which is the whole point of having a peek in front of the spend.
  defp match_spec(ticket, address) do
    [{{ticket, :"$1", address}, [{:<, {:const, now()}, :"$1"}], [true]}]
  end

  # Only when the table is filling. The sweep is an :ets.select_delete over every row,
  # and it used to run on every mint — which was needed back when a full table REFUSED
  # the request. Now that the global bound evicts instead, nothing depends on the table
  # being tidy at mint time: consume/2 checks expiry itself, and the 60 s sweep collects
  # whatever was written once and left alone.
  #
  # Measured before changing it: ~17 µs per mint at 200 rows, against ~12 µs at 50. The
  # table is far too small for this to matter today, and this is deliberately the cheap
  # version of the fix rather than a rewrite — it removes O(table) work from a path that
  # never needed it, without pretending there was a problem to solve.
  defp maybe_sweep do
    if :ets.info(@table, :size) > div(max_outstanding(), 2), do: sweep()
  end

  @doc false
  # Public for tests: drops everything already expired.
  def sweep do
    deadline = now()
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:"=<", :"$1", deadline}], [true]}])
  end

  @doc false
  def outstanding, do: :ets.info(@table, :size)

  # ---------------------------------------------------------------- server

  @impl GenServer
  def init(_opts) do
    # Owned by this process so it dies with the supervision tree, but public and
    # read-concurrent so issue/1 and consume/2 run in the caller — the upgrade path must
    # not queue behind a single process.
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    # write_concurrency because every refusal from every connection process writes here.
    :ets.new(@counters, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    # consume/2 and issue/1 both drop expired entries as they go; this is for the table
    # that was written to once and then left alone.
    sweep()
    report_refusals()
    schedule_sweep()
    {:noreply, state}
  end

  # The only place this module logs, and it is a timer rather than a caller. A rate is
  # also the more useful thing to read: "refused 340 in the last 60s" answers a question
  # that 340 identical lines answer worse.
  defp report_refusals do
    case :ets.take(@counters, :refused) do
      [{:refused, n}] when n > 0 ->
        Logger.warning(
          "refused #{n} ws ticket(s) in the last #{div(@sweep_every_ms, 1000)}s " <>
            "(cap #{max_per_address()} per address)"
        )

      _ ->
        :ok
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
