defmodule LiveCeci.SessionsTest do
  # async: false — one named GenServer and two application-env limits, shared by the VM.
  use ExUnit.Case, async: false

  alias LiveCeci.EnvSandbox

  import LiveCeci.Eventually

  alias LiveCeci.Sessions

  @local {127, 0, 0, 1}

  setup do
    # No save-and-restore of the caps here any more. It used to save with get_env/2 and
    # write the result back, which put `nil` once a sibling had deleted the key — and
    # `get_env/3`'s default does not apply to a key set to nil, so LiveCeci.Limits then
    # answered nil and limits_test.exs failed on one seed and passed on the next.
    # LiveCeci.EnvSandbox owns the restore now, per put, using fetch_env/2.

    # Every holder is registered here, so a FAILING assertion still releases its slots.
    # The first version cleaned up at the end of each test body; the race test failed,
    # skipped its cleanup, and left forty live sessions that made socket_lifecycle_test
    # fail for a reason it had nothing to do with.
    # start/1, NOT start_link/1. A linked Agent dies with the test process, which happens
    # BEFORE on_exit runs — so the cleanup that needs it crashed with "no process" and
    # reported that instead of whatever the test actually found.
    {:ok, spawned} = Agent.start(fn -> [] end)

    on_exit(fn ->
      # Kill, then WAIT for Sessions to reap them. Killing was fire-and-forget: the DOWNs
      # are processed asynchronously, so the next test could start with slots still held
      # and fail on a precondition it never chose. The re-audit flagged this as a latent
      # race; eight seeds and fifteen paired runs never reproduced it, which is exactly
      # the profile of the thing that fails once in CI a year from now.
      pids = Agent.get(spawned, & &1)
      for pid <- pids, do: Process.exit(pid, :kill)
      eventually(fn -> Enum.all?(pids, &(not Process.alive?(&1))) end)
      eventually(fn -> Sessions.total() == 0 end)
      Agent.stop(spawned)
    end)

    # The precondition the re-audit asked for. socket_lifecycle_test.exs also calls
    # Socket.init/1, which joins from 127.0.0.1 against this same singleton, so "the
    # table is empty when I start" is an assumption worth asserting rather than hoping.
    assert eventually(fn -> Sessions.total() == 0 end),
           "another test left #{Sessions.total()} sessions held"

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
      EnvSandbox.put_env(:max_sessions, 3)
      EnvSandbox.put_env(:max_sessions_per_address, 100)

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
      EnvSandbox.put_env(:max_sessions, 100)
      EnvSandbox.put_env(:max_sessions_per_address, 2)

      held = for _ <- 1..2, do: holder(spawned, {10, 0, 0, 7})
      assert Enum.all?(held, fn {_pid, r} -> r == :ok end)

      assert {_pid, {:error, :too_many_sessions}} = holder(spawned, {10, 0, 0, 7})
      # A different address is unaffected — that is what per-address means.
      assert {other, :ok} = holder(spawned, {10, 0, 0, 8})

      for {pid, _} <- held, do: stop(pid)
      stop(other)
    end
  end

  describe "the upstream backstop" do
    # This codebase has lost a billed upstream session three separate times, each through
    # a different door, and links caught none of them. Socket.terminate/2 closes the
    # session on an ordinary close; this covers the case where terminate never runs.

    defmodule ClosingProvider do
      @behaviour LiveCeci.Provider
      def open(_opts), do: {:error, :unused}
      def send_audio(_s, _pcm), do: :ok
      def commit_turn(_s), do: :ok
      def close({owner, tag}), do: send(owner, {:closed, tag}) && :ok
      def defaults, do: %{model: "m", voice: "v", model_env: "M", voice_env: "V"}
    end

    test "a brutally killed connection still has its upstream closed", %{spawned: spawned} do
      test = self()

      pid =
        spawn(fn ->
          :ok = Sessions.join(@local)
          Sessions.attach(ClosingProvider, {test, :from_backstop})
          send(test, :attached)
          receive do: (:never -> :ok)
        end)

      Agent.update(spawned, &[pid | &1])
      assert_receive :attached, 1_000
      # A cast, so give it a moment to land before the process dies.
      assert eventually(fn -> Sessions.total() == 1 end)

      # Killed. terminate/2 does not run, no cleanup gets the chance.
      Process.exit(pid, :kill)

      assert_receive {:closed, :from_backstop}, 1_000
      assert eventually(fn -> Sessions.total() == 0 end)
    end

    test "a connection that never attached does not break the release", %{spawned: spawned} do
      {pid, :ok} = holder(spawned)
      Process.exit(pid, :kill)

      assert eventually(fn -> Sessions.total() == 0 end)
    end
  end

  describe "release without cleanup" do
    test "a slot is released when its process dies, with no cleanup running", %{spawned: spawned} do
      # The property that survived the rewrite from Registry to GenServer, because it is
      # the one that matters most: a count you have to decrement means trusting that
      # something runs on the way out. terminate/2 does not run for a brutal kill, and a
      # count that leaks on crash walks down to zero available slots and then refuses
      # everyone until a restart. Monitors do not have that failure mode.
      EnvSandbox.put_env(:max_sessions, 2)
      EnvSandbox.put_env(:max_sessions_per_address, 2)

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
      EnvSandbox.put_env(:max_sessions, 5)
      EnvSandbox.put_env(:max_sessions_per_address, 5)

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

  describe "the refusal rate is reported off the call path" do
    # The counter accumulates until the timer reads it, and every other test in this file
    # refuses sessions on purpose — so each of these starts by draining whatever is
    # already there. Without that, the first version asserted "3" and read 4, which is a
    # true report of a count this test did not own.
    defp report do
      pid = Process.whereis(Sessions)

      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, :report)
        # A call, so it queues behind :report — without it capture_log returns before the
        # GenServer has read the message.
        :sys.get_state(pid)
      end)
    end

    test "a run of refusals is one log line from the timer, not one per caller",
         %{spawned: spawned} do
      # join/1 runs SERIALISED in front of every other upgrade. A Logger call there is
      # paid for by whoever is next in the queue, which is the same hazard, and the same
      # fix, as LiveCeci.Tickets.issue/1. The counter is asserted through the log the
      # timer emits, because the counter itself is private state.
      report()

      EnvSandbox.put_env(:max_sessions, 1)
      EnvSandbox.put_env(:max_sessions_per_address, 100)

      {held, :ok} = holder(spawned)
      for _ <- 1..3, do: assert({_pid, {:error, :too_many_sessions}} = holder(spawned))

      assert report() =~ "refused 3 session(s)"
      stop(held)
    end

    test "a quiet minute logs nothing" do
      report()

      refute report() =~ "refused"
    end
  end
end
