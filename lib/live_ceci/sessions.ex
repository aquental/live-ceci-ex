defmodule LiveCeci.Sessions do
  @moduledoc """
  A cap on how many live sessions may exist at once.

  Each open `/ws` connection holds an upstream session that is billed for as long as it
  lives. Nothing bounded how many could exist: the `Origin` check says *who* may ask and
  the ticket says *they asked first*, and neither says *how many*. Eight tabs is eight
  billed sessions, and so is eight of anything else that got a ticket.

  ## Why the decision is serialised

  The first version of this used a `Registry`: register, then count, then unregister
  again if over the line. It was wrong, and its own test caught it. Under contention
  every arrival registers before any of them counts, so they all see the total over the
  limit and they all back off — five slots, forty arrivals, **three** accepted. Refusing
  while slots are free is an outage, which is a worse failure than the one the cap
  exists to prevent.

  Deciding correctly means deciding one at a time. `join/1` is a `GenServer.call`, which
  costs one round trip **per connection**, not per frame — it is nowhere near the audio
  path, and the earlier note worrying about a mailbox in front of the hot path was
  measuring the wrong thing.

  ## Release without cleanup

  What the Registry did give for free was releasing a slot when its owner died, and that
  had to be kept: `LiveCeci.Socket.terminate/2` runs on an ordinary close but not on a
  brutal kill, and a count that leaks on crash walks down to zero available slots and
  then refuses everyone until a restart.

  So this monitors each holder instead. The slot belongs to the connection process and
  goes when it goes, whatever kills it. There is no `leave/0` on purpose — an explicit
  release is a thing that can be forgotten, and forgetting it is how a cap becomes an
  outage.
  """

  use GenServer

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Claims a slot for the calling process, or refuses. The slot is released when the
  caller dies.
  """
  @spec join(:inet.ip_address()) :: :ok | {:error, :too_many_sessions}
  def join(address), do: GenServer.call(__MODULE__, {:join, address})

  @doc """
  Whether a slot looks free, without claiming one.

  Advisory on purpose. The router asks this so it can refuse at capacity with a plain
  503, before the upgrade and before the ticket is spent — the alternative the audit
  suggested, claiming the slot in the router, would either burn the ticket on a refusal
  or hold a slot for a process that never became a session.

  Being advisory means it can be wrong: someone can take the last slot between this
  answer and `join/1`. That is fine, because `join/1` in `LiveCeci.Socket.init/1`
  remains the authoritative check and still refuses with 1013. This only turns the
  common case into a better-behaved one.
  """
  @spec available?(:inet.ip_address()) :: boolean()
  def available?(address), do: GenServer.call(__MODULE__, {:available?, address})

  @doc "How many sessions are live right now."
  @spec total() :: non_neg_integer()
  def total, do: GenServer.call(__MODULE__, :total)

  @doc "How many are live from one address."
  @spec per_address(:inet.ip_address()) :: non_neg_integer()
  def per_address(address), do: GenServer.call(__MODULE__, {:per_address, address})

  # ---------------------------------------------------------------- server

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:join, address}, {pid, _tag}, holders) do
    cond do
      map_size(holders) >= max_total() ->
        Logger.warning("refusing session: #{max_total()} already live")
        {:reply, {:error, :too_many_sessions}, holders}

      count_for(holders, address) >= max_per_address() ->
        Logger.warning(
          "refusing session from #{:inet.ntoa(address)}: " <>
            "#{max_per_address()} already live from that address"
        )

        {:reply, {:error, :too_many_sessions}, holders}

      true ->
        Process.monitor(pid)
        {:reply, :ok, Map.put(holders, pid, address)}
    end
  end

  def handle_call({:available?, address}, _from, holders) do
    free = map_size(holders) < max_total() and count_for(holders, address) < max_per_address()
    {:reply, free, holders}
  end

  def handle_call(:total, _from, holders), do: {:reply, map_size(holders), holders}

  def handle_call({:per_address, address}, _from, holders),
    do: {:reply, count_for(holders, address), holders}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, holders) do
    {:noreply, Map.delete(holders, pid)}
  end

  defp count_for(holders, address) do
    Enum.count(holders, fn {_pid, held} -> held == address end)
  end

  defp max_total, do: Application.get_env(:live_ceci, :max_sessions, 8)

  # Bound to loopback these two are the same number, since every address is 127.0.0.1.
  # They stop being the same the moment BIND_IP opens, which is the point of having both.
  defp max_per_address, do: Application.get_env(:live_ceci, :max_sessions_per_address, 4)
end
