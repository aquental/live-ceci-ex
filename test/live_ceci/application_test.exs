defmodule LiveCeci.ApplicationTest do
  # async: false — reads the running application's own supervision tree.
  use ExUnit.Case, async: false

  import LiveCeci.Eventually

  # The supervisor is started by the test VM itself, so this asserts against what is
  # actually running rather than re-starting anything. It was the only module in lib/
  # with no test at all, and the things it decides — where the listener binds, how long
  # a write may block — are exactly the ones that are invisible until they are wrong.

  test "everything the listener depends on starts before it" do
    # Order matters: an upgrade arriving before the ticket table or the session registry
    # exists would crash on them. which_children/1 returns children in REVERSE start
    # order, so Bandit comes first in this list and must.
    children = Supervisor.which_children(LiveCeci.Supervisor)
    ids = Enum.map(children, fn {id, _pid, _type, _mods} -> id end)

    assert [{Bandit, _ref}, LiveCeci.Data, LiveCeci.Sessions, LiveCeci.Tickets] = ids

    for {_id, pid, _type, _mods} <- children, do: assert(Process.alive?(pid))
  end

  test "it binds to loopback unless told otherwise" do
    # Bandit's own default is 0.0.0.0, which would put an unauthenticated WebSocket in
    # front of a metered API on the open LAN.
    assert Application.get_env(:live_ceci, :bind_ip) == {127, 0, 0, 1}
  end

  test "the listener survives a crashing child" do
    # one_for_one, so a dropped call never touches another listener. Killing Bandit is
    # the closest available proxy: the supervisor must bring it back rather than give up.
    [{{Bandit, _}, pid, _, _} | _] = Supervisor.which_children(LiveCeci.Supervisor)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    assert eventually(fn ->
             case Supervisor.which_children(LiveCeci.Supervisor) do
               [{{Bandit, _}, new, _, _} | _] when is_pid(new) ->
                 new != pid and Process.alive?(new)

               _ ->
                 false
             end
           end)
  end
end
