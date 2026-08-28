defmodule LiveDJ.ToolsTest do
  use ExUnit.Case, async: true

  alias LiveDJ.Tools

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
    # returns. This test is the guardrail from DESIGN.md §10 — it fails the moment a
    # handler starts doing real work.
    @budget_us 1_000

    test "every tool returns well inside the voice's latency budget" do
      for {name, args} <- [
            {"play_playlist", %{"mood" => "dream pop"}},
            {"play_track", %{"title" => "paper lamp"}},
            {"skip", %{}},
            {"pause", %{}}
          ] do
        {elapsed, _result} = :timer.tc(fn -> Tools.dispatch(name, args) end)

        assert elapsed < @budget_us,
               "#{name} took #{elapsed}µs — a live tool call must return instantly or the voice stalls"
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
