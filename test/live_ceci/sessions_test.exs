defmodule LiveCeci.SessionsTest do
  # async: false — one named GenServer and two application-env limits, shared by the VM.
  use ExUnit.Case, async: false

  alias LiveCeci.Sessions

  @local {127, 0, 0, 1}

  setup do
    previous = {
      Application.get_env(:live_ceci, :max_sessions),
      Application.get_env(:live_ceci, :max_sessions_per_address)
    }

    # Every holder is registered here, so a FAILING assertion still releases its slots.
    # The first version cleaned up at the end of each test body; the race test failed,
    # skipped its cleanup, and left forty live sessions that made socket_lifecycle_test
    # fail for a reason it had nothing to do with.
    # start/1, NOT start_link/1. A linked Agent dies with the test process, which happens
    # BEFORE on_exit runs — so the cleanup that needs it crashed with "no process" and
    # reported that instead of whatever the test actually found.
    {:ok, spawned} = Agent.start(fn -> [] end)

    on_exit(fn ->
      for pid <- Agent.get(spawned, & &1), do: Process.exit(pid, :kill)
      Agent.stop(spawned)
      {total, per} = previous
      Application.put_env(:live_ceci, :max_sessions, total)
      Application.put_env(:live_ceci, :max_sessions_per_address, per)
    end)

    %{spawned: spawned}
  end

  # Holds a slot in another process until told to stop, which is how a real session
  # behaves: the slot belongs to the connection, not to whoever asked for it.
  defp holder(spawned, address \\ @local) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:joined, Sessions.join(address)})
        receive do: (:release -> :ok)
      end)

    Agent.update(spawned, &[pid | &1])
    assert_receive {:joined, result}, 1_000
    {pid, result}
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  describe "the cap" do
    test "sessions are refused once the total is reached", %{spawned: spawned} do
      Application.put_env(:live_ceci, :max_sessions, 3)
      Application.put_env(:live_ceci, :max_sessions_per_address, 100)

      held = for _ <- 1..3, do: holder(spawned)
      assert Enum.all?(held, fn {_pid, result} -> result == :ok end)
      assert Sessions.total() == 3

      assert {_pid, {:error, :too_many_sessions}} = holder(spawned)
      assert Sessions.total() == 3

      for {pid, _} <- held, do: stop(pid)
    end

    test "one address cannot take every slot", %{spawned: spawned} do
      # Bound to loopback these two numbers coincide. They stop coinciding the moment
      # BIND_IP opens, which is the point of having both.
      Application.put_env(:live_ceci, :max_sessions, 100)
      Application.put_env(:live_ceci, :max_sessions_per_address, 2)

      held = for _ <- 1..2, do: holder(spawned, {10, 0, 0, 7})
      assert Enum.all?(held, fn {_pid, r} -> r == :ok end)

      assert {_pid, {:error, :too_many_sessions}} = holder(spawned, {10, 0, 0, 7})
      # A different address is unaffected — that is what per-address means.
      assert {other, :ok} = holder(spawned, {10, 0, 0, 8})

      for {pid, _} <- held, do: stop(pid)
      stop(other)
    end
  end

  describe "release without cleanup" do
    test "a slot is released when its process dies, with no cleanup running", %{spawned: spawned} do
      # The property that survived the rewrite from Registry to GenServer, because it is
      # the one that matters most: a count you have to decrement means trusting that
      # something runs on the way out. terminate/2 does not run for a brutal kill, and a
      # count that leaks on crash walks down to zero available slots and then refuses
      # everyone until a restart. Monitors do not have that failure mode.
      Application.put_env(:live_ceci, :max_sessions, 2)
      Application.put_env(:live_ceci, :max_sessions_per_address, 2)

      {first, :ok} = holder(spawned)
      {_second, :ok} = holder(spawned)
      assert Sessions.total() == 2

      # Killed, not asked. No terminate, no leave, nothing gets the chance to tidy up.
      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first, :killed}, 1_000

      assert eventually(fn -> Sessions.total() == 1 end)
      assert {_third, :ok} = holder(spawned)
    end
  end

  describe "the race that condemned the first design" do
    test "concurrent joins never refuse while slots are free", %{spawned: spawned} do
      # This is the test that condemned the first design. A Registry-based join that
      # registered and then counted let forty simultaneous arrivals all back off at once:
      # five slots, THREE accepted. Refusing while slots are free is an outage, which is
      # a worse failure than the one the cap exists to prevent. Serialising the decision
      # in a GenServer makes it exact.
      Application.put_env(:live_ceci, :max_sessions, 5)
      Application.put_env(:live_ceci, :max_sessions_per_address, 5)

      results =
        1..40
        |> Task.async_stream(fn _ -> holder(spawned) end, max_concurrency: 40, timeout: 5_000)
        |> Enum.map(fn {:ok, held} -> held end)

      accepted = Enum.filter(results, fn {_pid, r} -> r == :ok end)

      assert length(accepted) == 5,
             "cap is 5 and #{length(accepted)} were accepted — " <>
               "under is an outage, over is a leak"

      for {pid, _} <- results, do: stop(pid)
      assert eventually(fn -> Sessions.total() == 0 end)
    end
  end

  defp eventually(check, remaining \\ 1_000) do
    cond do
      check.() -> true
      remaining <= 0 -> false
      true -> Process.sleep(10) && eventually(check, remaining - 10)
    end
  end
end
