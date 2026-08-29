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

  `MAX_TICKETS` stops an unauthenticated endpoint growing a table without end. The
  first version enforced it globally and refused the NEWEST request, which turned a
  memory bound into an availability weapon: 200 mints from one address filled the table
  and every other user got `{:error, :too_many}` — reproduced, not theorised. It cleared
  30 seconds later when the tickets expired, so it was a denial for the duration of the
  flood rather than a permanent one, which is not much of a defence.

  Two changes fix it, and both matter:

    * **Per address.** One address can hold `MAX_TICKETS_PER_ADDRESS` at a time and no more, so
      filling the table from one place is no longer possible.
    * **Evict oldest.** If the table is somehow still full, the oldest ticket goes rather
      than the newest being refused. A ticket already near its expiry is worth less than
      the request in front of you, and refusing the newcomer is what let an attacker who
      arrived first keep everyone else out.
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
        # Global backstop. Evicts rather than refuses: the newest request is worth more
        # than the ticket closest to expiring anyway, and refusing it is what let whoever
        # arrived first lock the door behind them.
        if :ets.info(@table, :size) >= max_outstanding(), do: evict_oldest()

        ticket = @bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        :ets.insert(@table, {ticket, now() + @ttl_ms, address})
        {:ok, ticket}
    end
  end

  # A browser needs one ticket per connection, and a ticket that is minted but never
  # presented still occupies a slot for its full TTL — a failed connect, a closed tab
  # between the fetch and the upgrade. Twenty in thirty seconds is well past a reconnect
  # loop with any backoff at all.
  #
  # Configurable because "one address" is a deployment question, not a code one. On
  # loopback it is one person. Behind a NAT or a reverse proxy it is EVERYONE, and this
  # becomes the ceiling on concurrent users regardless of MAX_SESSIONS — demonstrated by
  # priv/spike/load_test.exs, where 50 simultaneous clients from 127.0.0.1 got 22
  # connections and 28 refusals with max_sessions set to 100.
  defp max_per_address, do: Application.get_env(:live_ceci, :max_tickets_per_address, 150)

  # DERIVED, not configured: twice the per-address bound. The two cannot drift apart,
  # which is the failure this shape exists to prevent — raising the per-address cap
  # without raising the global one turns the eviction that protects the table into
  # something that throws away tickets that were just issued. Measured at per-address 150
  # against a global of 200: two addresses filled the table and 100 of the first
  # address's 150 tickets were evicted before their owners could present them.
  #
  # Two is the ratio, so the headroom scales with whatever the per-address cap is set to.
  @outstanding_ratio 2
  defp max_outstanding, do: max_per_address() * @outstanding_ratio

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
