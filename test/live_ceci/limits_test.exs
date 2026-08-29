defmodule LiveCeci.LimitsTest do
  @moduledoc """
  The six ceilings, and the one relationship between them that is not a knob.
  """
  # async: false — every test here moves application env, which is global.
  use ExUnit.Case, async: false

  alias LiveCeci.EnvSandbox

  alias LiveCeci.Limits

  describe "the derived ticket bound" do
    test "is twice the per-address cap, whatever the per-address cap is" do
      # DERIVED, not configured, and this is the test that keeps it that way. The failure
      # it prevents was measured: with a per-address cap of 150 against a global bound of
      # 200 that had been set separately, two addresses filled the table and 100 of the
      # first address's tickets were evicted seconds after being issued.
      # on_exit, not a line after the loop: an assertion failing on the second iteration
      # would skip a plain cleanup and leave max_tickets_per_address at 10 for every test
      # that runs afterwards, including the eviction ones. Cleanup that only runs when
      # nothing went wrong is cleanup for the case that did not need it.

      for cap <- [1, 10, 150, 1_000] do
        EnvSandbox.put_env(:max_tickets_per_address, cap)
        assert Limits.tickets_outstanding() == cap * 2
      end
    end

    test "there is no configuration key that could set it independently" do
      # The whole point. If a future edit adds one, this fails rather than the drift
      # showing up as tickets being thrown away under load.
      source = File.read!("config/runtime.exs")

      refute source =~ "max_tickets_outstanding",
             "the global ticket bound must stay derived from the per-address cap"
    end
  end

  describe "defaults" do
    test "every ceiling answers without configuration, and none of them is zero" do
      # These are read on the connection path. A missing key must not be an exception
      # there, and a zero would be a cap that refuses everyone.
      for {name, value} <- [
            sessions_total: Limits.sessions_total(),
            sessions_per_address: Limits.sessions_per_address(),
            tickets_per_address: Limits.tickets_per_address(),
            tickets_outstanding: Limits.tickets_outstanding(),
            session_lifetime_ms: Limits.session_lifetime_ms(),
            session_byte_budget: Limits.session_byte_budget()
          ] do
        assert is_integer(value) and value > 0, "#{name} came back #{inspect(value)}"
      end
    end

    test "a session may not outlive its byte budget in ordinary speech" do
      # The two bounds exist to catch different things, and they are only both useful if
      # the byte budget is the LOOSER one for a normal conversation: 16 kHz s16le is
      # 32_000 bytes a second, so a session talking continuously for its whole lifetime
      # must still be under budget. Otherwise the clock would never be the thing that
      # fired, and a forgotten tab — the case the clock is for — would be cut off early
      # by a limit meant for a client sending faster than real time.
      continuous_bytes = div(Limits.session_lifetime_ms(), 1000) * 32_000

      assert continuous_bytes < Limits.session_byte_budget(),
             "the byte budget bites before the clock; the clock would never fire"
    end
  end
end
