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
    case :ets.lookup(@table, @snapshot_key) do
      [{@snapshot_key, data}] -> data
      [] -> @empty
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

    :ets.insert(@table, {@snapshot_key, data})
    {:ok, %{}}
  end

  defp expand_path(path) do
    if Path.type(path) == :absolute, do: path, else: Application.app_dir(:live_ceci, path)
  end
end
