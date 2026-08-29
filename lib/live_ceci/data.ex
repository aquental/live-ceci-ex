defmodule LiveCeci.Data do
  @moduledoc """
  In-memory clinic snapshot, loaded once from JSON (or a test map).

  `get_data/0` is an `:ets.lookup` in the caller. It is the primitive
  `LiveCeci.Tools.dispatch/2` may touch for reads. Writes go through `put_data/1`,
  also an `:ets.insert` in the caller. No `GenServer.call`, no `File`, no `Jason`
  on that path.

  A closed month lives until the node dies. Persistence back to the JSON file is
  deliberately omitted: this is a voice POC, not a store. A Data crash rebuilds
  from the file and loses in-memory closes.

  ## Writes are compare-and-swap, not last-writer-wins

  `put_data/1` replaces the whole snapshot, so a read-modify-write built out of
  `get_data/0` + `put_data/1` loses concurrent updates — reproduced: two sessions
  closing two DIFFERENT months, and the second write reverted the first, with both
  callers told "mês fechado, dados encaminhados ao contador". One of them was not.

  `replace/2` is the write every caller that read first should use. It is one
  `:ets.select_replace/2` with the old snapshot in a guard, which is atomic and still
  runs in the caller — 2.2 µs, so the microsecond rule holds. `put_data/1` stays for
  boot, tests and `reset/1`, where there is nothing to lose.

  A real database cannot live behind `get_data/0`. JSON vs Postgres do not share
  a latency class; putting blocking I/O here stalls the model's voice. A later
  store belongs off `dispatch/2`.
  """

  use GenServer

  @table __MODULE__
  @snapshot_key :snapshot

  @empty %{
    "patients" => [],
    "sessions" => [],
    "receipts" => [],
    "months" => %{}
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The current snapshot. One ETS lookup, copied to the caller.
  """
  @spec get_data() :: map()
  def get_data do
    # The `[]` clause guards an EMPTY table. It did not guard a MISSING one, which is the
    # failure that actually happens: the table is owned by this process, so it dies with
    # it, and between the crash and the restart :ets.lookup/2 raises ArgumentError.
    # Reproduced, and it matters because dispatch/2 runs INSIDE the provider's session
    # process — the raise took the live voice call down with it, for a read.
    case :ets.whereis(@table) do
      :undefined ->
        @empty

      table ->
        case :ets.lookup(table, @snapshot_key) do
          [{@snapshot_key, data}] -> data
          [] -> @empty
        end
    end
  end

  @doc """
  Replaces the snapshot. Used by `fechar_mes` and by tests. Not a call.
  """
  @spec put_data(map()) :: :ok
  def put_data(data) when is_map(data) do
    true = :ets.insert(@table, {@snapshot_key, data})
    :ok
  end

  @doc """
  Replaces the snapshot only if it is still the one the caller read.

  Returns `:stale` when someone else wrote in between, which is the caller's cue to
  read again and redo its decision — not to retry the write, because the decision was
  made against data that no longer exists.

  Exact equality, not a subset match: a map in a match-spec PATTERN matches structurally
  and would accept a subset, so the old snapshot goes in a `==` guard instead. Verified —
  `%{"a" => 1}` does not swap a stored `%{"a" => 1, "b" => 2}`.
  """
  @spec replace(map(), map()) :: :ok | :stale
  def replace(old, new) when is_map(old) and is_map(new) do
    spec = [
      {{@snapshot_key, :"$1"}, [{:==, :"$1", {:const, old}}], [{:const, {@snapshot_key, new}}]}
    ]

    case :ets.select_replace(@table, spec) do
      1 -> :ok
      0 -> :stale
    end
  end

  @doc false
  @spec reset(map()) :: :ok
  def reset(data), do: put_data(data)

  @doc false
  @spec load_source({:file, Path.t()} | {:map, map()}) :: map()
  def load_source({:file, path}) when is_binary(path) do
    path
    |> expand_path()
    |> File.read!()
    |> Jason.decode!()
  end

  def load_source({:map, map}) when is_map(map), do: map

  @doc false
  @spec rewrite_today(map(), Date.t()) :: map()
  def rewrite_today(data, %Date{} = date) when is_map(data) do
    iso = Date.to_iso8601(date)

    sessions =
      data
      |> Map.get("sessions", [])
      |> Enum.map(fn
        %{"date" => "today"} = session -> %{session | "date" => iso}
        session -> session
      end)

    Map.put(data, "sessions", sessions)
  end

  @impl GenServer
  def init(_opts) do
    # Owned by this process so it dies with the supervision tree, but public and
    # read-concurrent so get_data/0 and put_data/1 run in the caller — the voice
    # path must not queue behind a single process.
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    data =
      :live_ceci
      |> Application.fetch_env!(:clinic_source)
      |> load_source()
      |> rewrite_today(LiveCeci.Clock.today())

    today = LiveCeci.Clock.today()
    :ets.insert(@table, {@snapshot_key, data})
    schedule_rollover()
    {:ok, %{today: today}}
  end

  @impl GenServer
  def handle_info(:rollover, %{today: was} = state) do
    now = LiveCeci.Clock.today()

    # The fixture marks a demo row `"date" => "today"` and init/1 resolves it once. That
    # was the whole story, and past midnight it made Ceci say "nenhuma sessão hoje" with
    # four appointments in the snapshot — wearing the exact words of a genuinely empty
    # day, which is the part that makes it worth fixing rather than documenting.
    #
    # Rolling the rows the snapshot ALREADY has, rather than re-reading the file, is what
    # keeps a month closed by voice closed across midnight.
    if now != was, do: roll(was, now)

    schedule_rollover()
    {:noreply, %{state | today: now}}
  end

  defp roll(was, now) do
    data = get_data()
    # ISO strings on both sides. `was` is a Date in the process state, and the rows carry
    # the rendered date — comparing the two directly matches nothing, silently.
    from = Date.to_iso8601(was)
    to = Date.to_iso8601(now)

    sessions =
      data
      |> Map.get("sessions", [])
      |> Enum.map(fn
        %{"date" => ^from} = session -> %{session | "date" => to}
        session -> session
      end)

    # One CAS attempt. If a fechar_mes landed in the same instant its write wins and the
    # next tick rolls the dates — a demo fixture is not worth a retry loop on a timer.
    replace(data, Map.put(data, "sessions", sessions))
  end

  # Every ten minutes rather than a computed midnight: the clock is overridable in tests
  # and a laptop that slept through midnight would miss a single alarm anyway. Ten minutes
  # of staleness on a demo fixture is not worth a timezone database.
  defp schedule_rollover, do: Process.send_after(self(), :rollover, 600_000)

  defp expand_path(path) do
    if Path.type(path) == :absolute, do: path, else: Application.app_dir(:live_ceci, path)
  end
end
