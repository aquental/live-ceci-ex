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

  `@max_outstanding` is not a rate limit — it is the bound that stops an unauthenticated
  endpoint growing a table without end.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @ttl_ms 30_000
  @max_outstanding 200
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
    sweep()

    if :ets.info(@table, :size) >= @max_outstanding do
      Logger.warning("refusing to issue a ws ticket: #{@max_outstanding} already outstanding")
      {:error, :too_many}
    else
      ticket = @bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      :ets.insert(@table, {ticket, now() + @ttl_ms, address})
      {:ok, ticket}
    end
  end

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
