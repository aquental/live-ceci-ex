defmodule LiveCeci.ToolsTest do
  use ExUnit.Case, async: true

  alias LiveCeci.Tools

  describe "dispatch/2" do
    test "play_playlist returns a playlist command and an instant ok" do
      assert {%{action: "playlist", value: "lofi"}, %{result: "ok"}} =
               Tools.dispatch("play_playlist", %{"mood" => "lofi"})
    end

    test "play_track returns a track command" do
      assert {%{action: "track", value: "porcelain"}, %{result: "ok"}} =
               Tools.dispatch("play_track", %{"title" => "porcelain"})
    end

    test "skip and pause take no arguments" do
      assert {%{action: "skip"}, %{result: "ok"}} = Tools.dispatch("skip", %{})
      assert {%{action: "pause"}, %{result: "ok"}} = Tools.dispatch("pause", %{})
    end

    test "a missing argument degrades to an empty string rather than crashing the turn" do
      assert {%{action: "playlist", value: ""}, %{result: "ok"}} =
               Tools.dispatch("play_playlist", %{})
    end

    test "atom-keyed args work too" do
      assert {%{action: "playlist", value: "chill"}, %{result: "ok"}} =
               Tools.dispatch("play_playlist", %{mood: "chill"})
    end

    test "an unknown tool tells the model so, and emits no play command" do
      assert {nil, %{result: "unknown tool: teleport"}} = Tools.dispatch("teleport", %{})
    end
  end

  describe "the instant-return rule" do
    # Live function calls are SYNCHRONOUS: the model's voice is paused until the tool
    # returns. This is the guardrail from DESIGN.md §10, and it takes two measurements
    # because neither one catches both failure modes:
    #
    #   Process.sleep(60)          60_109 µs but only 6 reductions  -> wall clock only
    #   File.read! of a small file     40 µs and     40 reductions  -> reductions only
    #
    # So wall clock guards against blocking (sleep, network, GenServer.call) and
    # reductions guard against work (parsing, iterating, reading files).
    @cases [
      {"play_playlist", %{"mood" => "dream pop"}},
      {"play_track", %{"title" => "paper lamp"}},
      {"skip", %{}},
      {"pause", %{}}
    ]

    # Wall clock is the only instrument that sees a blocked scheduler, but it also sees
    # every unrelated stall on the machine. Now that reductions cover the work side, this
    # half only has to catch blocking, and the cheapest realistic offender — a GenServer
    # call, an HTTP request, a sleep — is orders of magnitude past 50 ms. Measured worst
    # case for the real clauses is 14 µs idle, 10 µs at a load average of 42.
    @budget_us 50_000

    test "no tool blocks the voice" do
      for {name, args} <- @cases do
        {elapsed, _result} = :timer.tc(fn -> Tools.dispatch(name, args) end)

        assert elapsed < @budget_us,
               "#{name} took #{elapsed}µs — a live tool call must return instantly or the voice stalls"
      end
    end

    # Reductions are immune to machine load, so this half never flakes. Every clause
    # measures 6-19, including one with a 1100-character mood, because dispatch only
    # pattern matches over plain data.
    @budget_reductions 40

    test "no tool does real work" do
      for {name, args} <- @cases do
        {:reductions, before} = Process.info(self(), :reductions)
        Tools.dispatch(name, args)
        {:reductions, now} = Process.info(self(), :reductions)

        assert now - before < @budget_reductions,
               "#{name} burned #{now - before} reductions — dispatch must stay a pattern match over plain data"
      end
    end
  end

  describe "declarations/0" do
    test "declares exactly the four music tools the persona promises" do
      names = Enum.map(Tools.declarations(), & &1.name)
      assert Enum.sort(names) == ["pause", "play_playlist", "play_track", "skip"]
    end

    test "every declared tool has a dispatch clause" do
      for %{name: name} <- Tools.declarations() do
        assert {_command, %{result: "ok"}} = Tools.dispatch(name, %{})
      end
    end

    test "live_tools/0 wraps them the way setup.tools expects" do
      assert [%{function_declarations: declarations}] = Tools.live_tools()
      assert declarations == Tools.declarations()
    end

    test "declarations survive a JSON round-trip to the API" do
      assert Tools.declarations() |> Jason.encode!() |> Jason.decode!() |> length() == 4
    end
  end
end
