defmodule LiveCeci.DataTest do
  # async: false — one named ETS table, shared by the whole VM.
  use ExUnit.Case, async: false

  import LiveCeci.Eventually

  alias LiveCeci.{Data, EnvSandbox}

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

  @empty %{"patients" => [], "sessions" => [], "receipts" => [], "months" => %{}}

  test "an empty table returns the empty snapshot, never raises" do
    :ets.delete_all_objects(Data)

    assert Data.get_data() == @empty
  end

  test "a MISSING table returns the empty snapshot too" do
    # The clause above guards an empty table, which is not the failure that happens. The
    # table is owned by the Data process and dies with it, so between a crash and the
    # restart :ets.lookup/2 raises ArgumentError — reproduced — and get_data/0 is called
    # from dispatch/2, which runs INSIDE the provider's session process. A raise there
    # took the live voice call down, for a read.
    #
    # The table is rebuilt by restarting Data, so this leaves nothing behind.
    pid = Process.whereis(Data)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    # The window: owner dead, supervisor has not necessarily replaced it yet.
    assert Data.get_data() == @empty

    assert {%{action: "pacientes"}, %{result: "nenhum paciente"}} =
             LiveCeci.Tools.dispatch("listar_pacientes", %{})

    assert eventually(fn -> is_pid(Process.whereis(Data)) end)
  end

  test "replace/2 swaps only if the snapshot is still the one that was read" do
    read = Data.get_data()
    next = %{read | "patients" => [%{"id" => "p9", "apelido" => "Z.Z."}]}

    assert :ok = Data.replace(read, next)
    assert Data.get_data() == next

    # The stale caller. Its decision was made against a snapshot that no longer exists,
    # so its write must not land — this is the whole reason fechar_mes stopped using
    # put_data/1.
    assert :stale = Data.replace(read, %{read | "receipts" => [%{"valor" => "1"}]})
    assert Data.get_data() == next
  end

  test "replace/2 compares exactly, not as a subset" do
    # A map in a match-spec PATTERN matches structurally and would accept a subset, which
    # would make the compare-and-swap accept a caller that read a smaller snapshot.
    full = Data.get_data()
    assert :stale = Data.replace(%{"patients" => full["patients"]}, %{"patients" => []})
    assert Data.get_data() == full
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

  describe "the demo fixture's \"today\" across midnight" do
    test "the rollover moves the rows the snapshot already has" do
      # rewrite_today/2 runs once in init/1, so before the rollover existed a node up past
      # midnight said "nenhuma sessão hoje" with four appointments in the snapshot —
      # wearing the exact words of a genuinely empty day, which is the part that made this
      # worth fixing rather than documenting.
      Data.reset(%{
        "patients" => [],
        "receipts" => [],
        "months" => %{"agosto" => %{"status" => "closed", "year" => 2026}},
        "sessions" => [
          %{"patient_id" => "p1", "date" => "2026-08-15", "time" => "09:00"},
          %{"patient_id" => "p2", "date" => "2026-08-01", "time" => "10:00"}
        ]
      })

      pid = Process.whereis(Data)
      EnvSandbox.put_env(:today, ~D[2026-08-16])
      on_exit(fn -> send(pid, :rollover) end)

      send(pid, :rollover)
      # A call, so it queues behind :rollover — without it this reads the table before the
      # GenServer has handled the message.
      :sys.get_state(pid)

      dates = Enum.map(Data.get_data()["sessions"], & &1["date"])
      assert dates == ["2026-08-16", "2026-08-01"], "got #{inspect(dates)}"

      # And it rolled the snapshot rather than re-reading the file, so a month closed by
      # voice is still closed on the other side of midnight.
      assert Data.get_data()["months"]["agosto"]["status"] == "closed"
    end

    test "a rollover on the same day changes nothing" do
      Data.reset(%{@snapshot | "sessions" => [%{"date" => "2026-08-15", "time" => "09:00"}]})
      before = Data.get_data()

      pid = Process.whereis(Data)
      send(pid, :rollover)
      :sys.get_state(pid)

      assert Data.get_data() == before
    end
  end
end
