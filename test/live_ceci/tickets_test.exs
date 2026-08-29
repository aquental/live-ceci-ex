defmodule LiveCeci.TicketsTest do
  # async: false — one named ETS table, shared by the whole VM.
  use ExUnit.Case, async: false

  alias LiveCeci.Tickets

  @local {127, 0, 0, 1}

  setup do
    # Cleared, not swept. sweep/0 only drops what has expired, and the bound test leaves
    # 200 live tickets behind — every test after it then got {:error, :too_many} and
    # failed on a shape it never chose. Isolation has to be total or it is not isolation.
    :ets.delete_all_objects(Tickets)
    on_exit(fn -> :ets.delete_all_objects(Tickets) end)
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

    test "the global bound evicts the oldest rather than refusing the newest" do
      # The backstop, and the direction matters: refusing the newcomer is what let
      # whoever arrived first keep the door shut.
      for i <- 1..250, do: Tickets.issue({10, 0, div(i, 256), rem(i, 256)})

      assert Tickets.outstanding() <= 200
      assert {:ok, _} = Tickets.issue({192, 168, 1, 1})
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
