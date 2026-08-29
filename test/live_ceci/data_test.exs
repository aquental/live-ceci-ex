defmodule LiveCeci.DataTest do
  # async: false — one named ETS table, shared by the whole VM.
  use ExUnit.Case, async: false

  alias LiveCeci.Data

  @snapshot %{
    "patients" => [%{"id" => "p1", "apelido" => "M.S."}],
    "sessions" => [],
    "receipts" => [],
    "months" => %{}
  }

  setup do
    original = Data.get_data()
    Data.reset(@snapshot)
    on_exit(fn -> Data.reset(original) end)
    :ok
  end

  test "get_data/0 returns what was reset" do
    assert Data.get_data() == @snapshot
  end

  test "put_data/1 is visible to the next get_data/0" do
    next = %{@snapshot | "patients" => [%{"id" => "p2", "apelido" => "R.L."}]}
    assert :ok = Data.put_data(next)
    assert Data.get_data() == next
  end

  test "get_data/0 is an ETS lookup, not a GenServer.call" do
    pid = Process.whereis(Data)
    :sys.suspend(pid)

    try do
      task = Task.async(fn -> Data.get_data() end)
      assert {:ok, @snapshot} = Task.yield(task, 200) || Task.shutdown(task)
    after
      :sys.resume(pid)
    end
  end

  test "an empty table returns the empty snapshot, never raises" do
    :ets.delete_all_objects(Data)

    assert Data.get_data() == %{
             "patients" => [],
             "sessions" => [],
             "receipts" => [],
             "months" => %{}
           }
  end

  test "load_source/1 reads a temp file without talking to the named server" do
    path = Path.join(System.tmp_dir!(), "clinic-#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"patients":[{"id":"z","apelido":"Z"}],"sessions":[]}))
    on_exit(fn -> File.rm(path) end)

    assert %{"patients" => [%{"id" => "z", "apelido" => "Z"}]} =
             Data.load_source({:file, path})
  end

  test "rewrite_today/2 replaces the sentinel once, leaving ISO dates alone" do
    data = %{
      "sessions" => [
        %{"date" => "today", "time" => "09:00"},
        %{"date" => "2026-08-01", "time" => "10:00"}
      ]
    }

    assert %{
             "sessions" => [
               %{"date" => "2026-08-15", "time" => "09:00"},
               %{"date" => "2026-08-01", "time" => "10:00"}
             ]
           } = Data.rewrite_today(data, ~D[2026-08-15])
  end
end
