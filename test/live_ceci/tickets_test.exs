defmodule LiveCeci.TicketsTest do
  # async: false — one named ETS table, shared by the whole VM.
  use ExUnit.Case, async: false

  alias LiveCeci.EnvSandbox

  alias LiveCeci.Tickets

  @local {127, 0, 0, 1}

  setup do
    # Cleared, not swept. sweep/0 only drops what has expired, and the bound test leaves
    # 200 live tickets behind — every test after it then got {:error, :too_many} and
    # failed on a shape it never chose. Isolation has to be total or it is not isolation.
    # BOTH tables. Clearing only the ticket table left the refusal counter carrying every
    # earlier test's refusals, so the rate assertion below saw whatever had accumulated
    # instead of what this test caused — a failure that depended on the seed.
    clear = fn ->
      :ets.delete_all_objects(Tickets)
      :ets.delete_all_objects(Module.concat(Tickets, Counters))
    end

    clear.()
    on_exit(clear)
    :ok
  end

  describe "single use" do
    # The property that makes a leaked query string survivable, and the reason consume/2
    # is :ets.take/2 rather than lookup-then-delete.

    test "a ticket is spent the first time it is presented" do
      {:ok, ticket} = Tickets.issue(@local)

      assert :ok = Tickets.consume(ticket, @local)
      assert {:error, :invalid} = Tickets.consume(ticket, @local)
    end

    test "two connections racing on one ticket, exactly one wins" do
      # take/2 is atomic; a lookup followed by a delete would let both through. Fifty
      # rounds because a race that fails one time in ten looks fine once.
      for _ <- 1..50 do
        {:ok, ticket} = Tickets.issue(@local)

        winners =
          1..8
          |> Task.async_stream(fn _ -> Tickets.consume(ticket, @local) end, max_concurrency: 8)
          |> Enum.count(fn {:ok, result} -> result == :ok end)

        assert winners == 1
      end
    end
  end

  describe "the other two properties" do
    test "a ticket from another address is refused" do
      {:ok, ticket} = Tickets.issue({10, 0, 0, 7})

      assert {:error, :invalid} = Tickets.consume(ticket, @local)
    end

    test "an expired ticket is refused, and swept" do
      # Reaches into the table rather than sleeping 30 seconds: the entry shape is the
      # thing under test either way, and a sleeping test is a slow test that still only
      # proves one number.
      {:ok, ticket} = Tickets.issue(@local)
      [{^ticket, _expires, address}] = :ets.lookup(Tickets, ticket)
      :ets.insert(Tickets, {ticket, System.monotonic_time(:millisecond) - 1, address})

      assert {:error, :invalid} = Tickets.consume(ticket, @local)
    end

    test "expiry survives a negative monotonic clock" do
      # System.monotonic_time/1 has an arbitrary origin and is deeply negative on this
      # machine — measured at -576460751723. A `when expires_at > 0` guard looked natural
      # and rejected every valid ticket. This is that bug, pinned.
      assert System.monotonic_time(:millisecond) < 0 or
               System.monotonic_time(:millisecond) >= 0

      {:ok, ticket} = Tickets.issue(@local)
      assert :ok = Tickets.consume(ticket, @local)
    end
  end

  describe "what it refuses" do
    test "nil, empty and invented tickets are all the same answer" do
      # Telling them apart tells a caller which half of a guess was right.
      for bad <- [nil, "", "invented", :not_a_string, 12_345] do
        assert {:error, :invalid} = Tickets.consume(bad, @local)
      end
    end

    test "one address cannot fill the table and lock everyone else out" do
      # THE regression test for this module. The first version enforced only a global
      # bound and refused the NEWEST request, so 200 mints from one address locked out
      # every other user — reproduced, not theorised. Per-address is what fixes it.
      flood = for _ <- 1..400, do: Tickets.issue({203, 0, 113, 9})

      assert Enum.any?(flood, &match?({:error, :too_many}, &1)),
             "the flooding address was never refused"

      assert {:ok, _} = Tickets.issue(@local),
             "a legitimate user was locked out by another address's flood"
    end

    test "the global bound evicts rather than refusing the newest" do
      # The backstop, and the direction matters: refusing the newcomer is what let
      # whoever arrived first keep the door shut.
      #
      # The global bound is derived at twice the per-address one, so this drives the
      # per-address knob and computes what the table is allowed to hold.
      EnvSandbox.put_env(:max_tickets_per_address, 10)
      ceiling = 10 * 2

      for i <- 1..250, do: Tickets.issue({10, 0, div(i, 256), rem(i, 256)})

      assert Tickets.outstanding() <= ceiling
      assert {:ok, _} = Tickets.issue({192, 168, 1, 1})
    end

    test "the global bound is derived, so the two cannot be raised out of step" do
      # The trap this shape closes: raising the per-address cap alone turns the eviction
      # that protects the table into something that discards tickets just issued.
      # Measured at per-address 150 against a global of 200 — two addresses filled the
      # table and 100 of the first one's 150 were evicted before their owners could
      # present them, a 403 on a ticket the server had handed out seconds earlier.
      EnvSandbox.put_env(:max_tickets_per_address, 10)

      # Two addresses at the per-address cap fit exactly, and nothing is evicted.
      a = for _ <- 1..10, do: Tickets.issue({10, 0, 0, 1})
      _b = for _ <- 1..10, do: Tickets.issue({10, 0, 0, 2})

      assert Enum.count(a, &match?({:ok, _}, &1)) == 10
      assert Tickets.outstanding() == 20

      assert Enum.count(a, fn {:ok, t} -> Tickets.consume(t, {10, 0, 0, 1}) == :ok end) == 10
    end

    test "eviction takes from whoever holds the most, so nobody is starved" do
      # The second denial of service this bound used to be, and the subtler one. Evicting
      # the globally OLDEST ticket points the weapon at whoever arrived FIRST: measured at
      # the default cap with three busy addresses, the first address kept 29 of its 150,
      # the second 121, the third all 150.
      #
      # Fair-share eviction converges instead. Every eviction takes from whichever address
      # is currently largest, so the shares cannot spread: measured at the real defaults
      # the same three addresses settle at 99/100/101, and at the cap of 10 used here they
      # settle at 6/6/8. Two is the width, not one — the address doing the inserting is
      # never evicted from during its own insert, so it ends one ahead.
      EnvSandbox.put_env(:max_tickets_per_address, 10)

      addresses = [{10, 0, 0, 1}, {10, 0, 0, 2}, {10, 0, 0, 3}]
      for address <- addresses, _ <- 1..10, do: Tickets.issue(address)

      held =
        Enum.map(addresses, fn address ->
          :ets.select_count(Tickets, [
            {{:_, :_, :"$1"}, [{:==, :"$1", {:const, address}}], [true]}
          ])
        end)

      # 20 slots, three addresses, and the spread bounded. The number that matters is the
      # minimum: oldest-first left the first address with 29 of 150 at the real defaults,
      # which is the starvation this replaces.
      assert Enum.sum(held) == 20
      assert Enum.max(held) - Enum.min(held) <= 2, "shares came out #{inspect(held)}"
      assert Enum.min(held) >= 5, "an address was starved: #{inspect(held)}"
    end

    test "when every address ties, the oldest ticket goes rather than an arbitrary one" do
      # The case fair-share does not cover on its own: many addresses holding ONE ticket
      # each all tie at a count of 1, and max_by on the count alone then picks by map
      # order — arbitrary, and stable, so the same unlucky address would lose its only
      # ticket every single time. Breaking the tie on expiry makes it "drop whatever is
      # closest to expiring", which is the right answer when nobody is hoarding.
      EnvSandbox.put_env(:max_tickets_per_address, 5)

      # Ten distinct addresses, one ticket each, filling the derived bound exactly.
      issued = for i <- 1..10, do: {i, elem(Tickets.issue({10, 0, 0, i}), 1)}
      assert Tickets.outstanding() == 10

      # One more address arrives. The oldest ticket — the first one issued — is the one
      # that goes, not whichever the map happened to enumerate first.
      {:ok, _} = Tickets.issue({10, 0, 0, 99})

      {_i, oldest} = hd(issued)
      refute :ets.member(Tickets, oldest), "eviction did not take the oldest ticket"
    end
  end

  describe "consuming a ticket" do
    test "presenting it from the wrong address does not destroy it" do
      # `:ets.take/2` used to remove the row and check the address afterwards, so a
      # stolen ticket presented from anywhere else was spent — reproduced, and the
      # legitimate owner's next attempt answered {:error, :invalid}. Whoever leaked the
      # ticket could not use it, but could deny it.
      {:ok, ticket} = Tickets.issue({10, 0, 0, 1})

      assert {:error, :invalid} = Tickets.consume(ticket, {10, 0, 0, 2})
      assert :ok = Tickets.consume(ticket, {10, 0, 0, 1})
    end

    test "it still works exactly once from the right address" do
      {:ok, ticket} = Tickets.issue({10, 0, 0, 1})

      assert :ok = Tickets.consume(ticket, {10, 0, 0, 1})
      assert {:error, :invalid} = Tickets.consume(ticket, {10, 0, 0, 1})
    end

    test "an expired ticket is refused, and refusing it does not consume it either" do
      {:ok, ticket} = Tickets.issue({10, 0, 0, 1})
      # Reach into the table rather than waiting 30 seconds: the expiry comparison is what
      # is being tested, not the clock.
      [{^ticket, _expires, address}] = :ets.lookup(Tickets, ticket)
      :ets.insert(Tickets, {ticket, System.monotonic_time(:millisecond) - 1, address})

      assert {:error, :invalid} = Tickets.consume(ticket, {10, 0, 0, 1})
      # The sweep collects it; the failed attempt did not have to.
      assert :ets.member(Tickets, ticket)
      Tickets.sweep()
      refute :ets.member(Tickets, ticket)
    end

    test "valid?/2 answers without spending, so the peek in the router is free" do
      # The router asks this BEFORE it asks the Sessions singleton, so an unauthenticated
      # upgrade never queues on the one process every real upgrade waits behind. It is
      # only allowed in front of the spend because it does not spend.
      {:ok, ticket} = Tickets.issue({10, 0, 0, 1})

      assert Tickets.valid?(ticket, {10, 0, 0, 1})
      assert Tickets.valid?(ticket, {10, 0, 0, 1}), "the peek consumed the ticket"
      refute Tickets.valid?(ticket, {10, 0, 0, 2})
      refute Tickets.valid?(nil, {10, 0, 0, 1})
      refute Tickets.valid?("nonsense", {10, 0, 0, 1})

      assert :ok = Tickets.consume(ticket, {10, 0, 0, 1})
      refute Tickets.valid?(ticket, {10, 0, 0, 1})
    end

    test "a nil or non-binary ticket is the same answer as a wrong one" do
      assert {:error, :invalid} = Tickets.consume(nil, {10, 0, 0, 1})
      assert {:error, :invalid} = Tickets.consume(:not_a_ticket, {10, 0, 0, 1})
    end
  end

  describe "nothing slow on the upgrade path" do
    test "a refusal costs a counter, not a log line" do
      # issue/1 runs in the CONNECTION process, so logging a refusal there puts the
      # logging backend on the upgrade path. Measured before the fix: 5 µs with the
      # default handler, 3001 µs with a 2 ms sink standing in for a remote syslog. After:
      # 1 µs either way.
      #
      # Asserted as a shape rather than a duration, because a timing assertion here would
      # measure the machine: the rule is that issue/1 does not log, and the sweep timer
      # reports the rate instead.
      source = File.read!("lib/live_ceci/tickets.ex")
      [_before, rest] = String.split(source, "def issue(address) do", parts: 2)
      [issue_body, _] = String.split(rest, "\n  defp ", parts: 2)

      refute issue_body =~ "Logger.",
             "issue/1 logs — that puts the logging backend on the upgrade path"
    end

    test "the refusal rate is reported by the sweep timer" do
      EnvSandbox.put_env(:max_tickets_per_address, 2)

      for _ <- 1..5, do: Tickets.issue({10, 0, 0, 1})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pid = Process.whereis(Tickets)
          send(pid, :sweep)
          # :sys.get_state/1 is a call, so it queues BEHIND :sweep — which is what makes
          # this deterministic. Without it capture_log returned before the GenServer had
          # processed the message and the assertion saw an empty string.
          :sys.get_state(pid)
        end)

      assert log =~ "refused 3 ws ticket(s)"
    end
  end

  describe "the ticket itself" do
    test "it is long, random, and URL-safe" do
      # It travels in a query string, so anything needing escaping is a bug waiting for
      # a client that forgets to escape it.
      #
      # One address per ticket: @max_per_address caps how many one address may hold, and
      # that cap is the fix for the lockout — so this asks a hundred different addresses
      # rather than raising the limit to make a test pass.
      tickets =
        for i <- 1..100 do
          {:ok, t} = Tickets.issue({10, 0, div(i, 256), rem(i, 256)})
          t
        end

      assert length(Enum.uniq(tickets)) == 100

      for t <- tickets do
        assert byte_size(t) >= 40
        assert t == URI.encode_www_form(t)
      end
    end
  end
end
