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

  ## The bound, and the denial of service it used to be

  `@max_outstanding` stops an unauthenticated endpoint growing a table without end. The
  first version enforced it globally and refused the NEWEST request, which turned a
  memory bound into an availability weapon: 200 mints from one address filled the table
  and every other user got `{:error, :too_many}` — reproduced, not theorised. It cleared
  30 seconds later when the tickets expired, so it was a denial for the duration of the
  flood rather than a permanent one, which is not much of a defence.

  Two changes fix it, and both matter:

    * **Per address.** One address can hold `@max_per_address` at a time and no more, so
      filling the table from one place is no longer possible.
    * **Evict oldest.** If the table is somehow still full, the oldest ticket goes rather
      than the newest being refused. A ticket already near its expiry is worth less than
      the request in front of you, and refusing the newcomer is what let an attacker who
      arrived first keep everyone else out.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @ttl_ms 30_000
  @max_outstanding 200
  # A browser needs one ticket per connection, and a ticket that is minted but never
  # presented still occupies a slot for its full TTL — a failed connect, a closed tab
  # between the fetch and the upgrade. Twenty in thirty seconds is already well past a
  # reconnect loop with any backoff at all, and it still takes ten cooperating addresses
  # to reach the global bound, where eviction takes over.
  @max_per_address 20
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
      count_for(address) >= @max_per_address ->
        # The bound that actually stops the flood, because it is scoped to whoever is
        # flooding. Refusing here denies one address, not everyone.
        Logger.warning(
          "refusing a ws ticket for #{:inet.ntoa(address)}: " <>
            "#{@max_per_address} already outstanding from there"
        )

        {:error, :too_many}

      true ->
        # Global backstop. Evicts rather than refuses: the newest request is worth more
        # than the ticket closest to expiring anyway, and refusing it is what let whoever
        # arrived first lock the door behind them.
        if :ets.info(@table, :size) >= @max_outstanding, do: evict_oldest()

        ticket = @bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        :ets.insert(@table, {ticket, now() + @ttl_ms, address})
        {:ok, ticket}
    end
  end

  defp count_for(address) do
    :ets.select_count(@table, [{{:_, :_, :"$1"}, [{:==, :"$1", {:const, address}}], [true]}])
  end

  defp evict_oldest do
    case :ets.foldl(fn {t, exp, _a}, acc -> min_by_expiry(acc, {t, exp}) end, nil, @table) do
      {ticket, _expires} -> :ets.delete(@table, ticket)
      nil -> :ok
    end
  end

  defp min_by_expiry(nil, candidate), do: candidate

  defp min_by_expiry({_t, best} = acc, {_ct, exp} = candidate),
    do: if(exp < best, do: candidate, else: acc)

  @doc """
  Spends a ticket. Succeeds at most once per ticket, and only from the address it was
  minted for.

  A wrong, expired, replayed or absent ticket is the same answer on purpose: telling
  them apart tells a caller which half of a guess was right.
  """
  @spec consume(String.t() | nil, :inet.ip_address()) :: :ok | {:error, :invalid}
  def consume(ticket, address) when is_binary(ticket) do
    # take/2 removes and returns atomically, so two connections racing on the same
    # ticket cannot both win. A GenServer.call would serialise this too, and would put
    # the ticket check on a single process in front of every upgrade.
    # No `when expires_at > 0` here, however natural it looks. System.monotonic_time/1
    # has an arbitrary origin and is deeply negative on this machine — measured at
    # -576460751723 — so that guard rejected every valid ticket. The comparison below is
    # the actual check, and it holds whatever the origin is.
    case :ets.take(@table, ticket) do
      [{^ticket, expires_at, ^address}] ->
        if now() < expires_at, do: :ok, else: {:error, :invalid}

      _other ->
        {:error, :invalid}
    end
  end

  def consume(_ticket, _address), do: {:error, :invalid}

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
    if :ets.info(@table, :size) > div(@max_outstanding, 2), do: sweep()
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
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    # consume/2 and issue/1 both drop expired entries as they go; this is for the table
    # that was written to once and then left alone.
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
