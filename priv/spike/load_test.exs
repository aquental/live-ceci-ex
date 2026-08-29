# Load test: how does the server behave with many real sessions at once?
#
#     set -a && . ./.env && set +a && mix run --no-start priv/spike/load_test.exs
#
#     LOAD_CLIENTS=50 LOAD_SECONDS=20 mix run --no-start priv/spike/load_test.exs
#
# Real Bandit, real WebSockets, real tickets, real caps, real audio frames at the rate a
# browser sends them. The one thing that is fake is the provider, and that is deliberate:
# a hundred real sessions would cost real money and would measure xAI's capacity rather
# than this server's. The stub echoes each mic frame back as voice, so the downstream
# push, the shedding and the browser-facing framing are all exercised too.
#
# What this can and cannot tell you: it measures OUR code under concurrency — memory per
# session, mailbox behaviour, whether the caps hold, where the first thing breaks. It
# says nothing about provider latency, which the measured 985/1220 ms dominates anyway.

defmodule Load.StubProvider do
  @moduledoc false
  @behaviour LiveCeci.Provider

  # A process per session, like a real provider has, so process accounting is honest.
  def open(opts) do
    owner = Keyword.fetch!(opts, :owner)
    {:ok, spawn_link(fn -> loop(owner) end)}
  end

  def send_audio(session, pcm) do
    send(session, {:mic, pcm})
    :ok
  end

  def commit_turn(_session), do: :ok

  def close(session) do
    if is_pid(session) and Process.alive?(session), do: send(session, :stop)
    :ok
  end

  # Echoes the mic frame straight back as voice. Same shape the real providers emit, so
  # LiveCeci.Socket cannot tell the difference.
  defp loop(owner) do
    receive do
      {:mic, pcm} ->
        send(owner, {:provider, {:voice, pcm}})
        loop(owner)

      :stop ->
        :ok
    end
  end
end

defmodule Load.Client do
  @moduledoc false
  use WebSockex

  def start(url, owner) do
    WebSockex.start_link(url, __MODULE__, %{owner: owner, voice: 0},
      extra_headers: [{"Origin", "http://127.0.0.1"}]
    )
  end

  @impl true
  def handle_frame({:binary, _pcm}, state) do
    send(state.owner, :voice)
    {:ok, %{state | voice: state.voice + 1}}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    send(state.owner, {:closed, reason})
    {:ok, state}
  end
end

defmodule Load do
  @moduledoc false

  @frame_bytes 3_200
  @frame_ms 100

  def run do
    clients = LiveCeci.env_int("LOAD_CLIENTS", 50, 1..20_000)
    seconds = LiveCeci.env_int("LOAD_SECONDS", 20, 1..600)

    start_apps()
    Application.put_env(:live_ceci, :provider, Load.StubProvider)
    Application.put_env(:live_ceci, :max_sessions, clients * 2)
    Application.put_env(:live_ceci, :max_sessions_per_address, clients * 2)
    # Every client here comes from 127.0.0.1, so without this the per-address TICKET cap
    # is what the run measures rather than the server. Found the hard way: 50 clients,
    # max_sessions 100, and still 28 refusals — all of them at the ticket desk.
    Application.put_env(:live_ceci, :max_tickets_per_address, clients * 2)

    port = start_server()
    frames = div(seconds * 1_000, @frame_ms)

    IO.puts("""

    load test — #{clients} concurrent sessions, #{seconds}s, #{frames} frames each
      provider   stub (echoes mic back as voice), so this measures THIS server
      rate       #{div(1_000, @frame_ms)} frames/s/session = #{clients * div(1_000, @frame_ms)} frames/s total
    """)

    before = snapshot()
    started = System.monotonic_time(:millisecond)

    results =
      1..clients
      |> Task.async_stream(fn _ -> session(port, frames) end,
        max_concurrency: clients,
        timeout: (seconds + 60) * 1_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    elapsed = System.monotonic_time(:millisecond) - started

    :erlang.garbage_collect()
    Process.sleep(500)
    report(results, before, snapshot(), elapsed, clients, frames)
  end

  # One client: mint a ticket, connect, stream at real time, count what comes back.
  defp session(port, frames) do
    with {:ok, ticket} <- ticket(port),
         {:ok, ws} <- Load.Client.start("ws://127.0.0.1:#{port}/ws?ticket=#{ticket}", self()) do
      pcm = :binary.copy(<<0>>, @frame_bytes)
      start = now()

      sent =
        Enum.reduce(1..frames, 0, fn i, acc ->
          case send_frame(ws, pcm) do
            :ok ->
              sleep_until(start + i * @frame_ms)
              acc + 1

            :error ->
              acc
          end
        end)

      Process.sleep(300)
      received = drain_voice(0)
      WebSockex.cast(ws, :stop)
      %{status: :ok, sent: sent, received: received}
    else
      {:error, reason} -> %{status: :refused, reason: reason, sent: 0, received: 0}
    end
  end

  defp send_frame(ws, pcm) do
    WebSockex.send_frame(ws, {:binary, pcm})
  catch
    :exit, _ -> :error
  end

  defp drain_voice(n) do
    receive do
      :voice -> drain_voice(n + 1)
      _other -> drain_voice(n)
    after
      0 -> n
    end
  end

  # ---- reporting --------------------------------------------------------------

  defp report(results, before, after_, elapsed, clients, frames) do
    ok = Enum.count(results, &(&1.status == :ok))
    sent = Enum.sum(Enum.map(results, & &1.sent))
    received = Enum.sum(Enum.map(results, & &1.received))
    expected = ok * frames

    IO.puts("""
    sessions    #{ok}/#{clients} connected, #{clients - ok} refused
    frames up   #{sent}/#{expected} sent#{pct(sent, expected)}
    frames down #{received}/#{sent} echoed back#{pct(received, sent)}
    wall clock  #{div(elapsed, 1000)}s

    memory      total #{mb(after_.total - before.total)} MB grown, #{mb(after_.binary - before.binary)} MB binary
                #{kb(div(max(after_.total - before.total, 0), max(ok, 1)))} KB per session
    processes   #{after_.procs - before.procs} left over (0 is the answer)
    """)

    reasons(results)
    verdict(ok, clients, sent, expected, received, after_.procs - before.procs)
  end

  # WHY they were refused, not a guess. The first version of this reported "the cap or
  # the ticket bound bit first" for every refusal, which it had no way of knowing — and
  # at 5000 clients it was wrong: the caps were set to 10_000 and what actually failed
  # was the connection itself.
  defp reasons(results) do
    grouped =
      results
      |> Enum.filter(&(&1.status == :refused))
      |> Enum.frequencies_by(&classify(&1.reason))

    for {reason, n} <- Enum.sort_by(grouped, &(-elem(&1, 1))) do
      IO.puts("  refused #{String.pad_leading("#{n}", 5)}  #{reason}")
    end

    if grouped != %{}, do: IO.puts("")
  end

  defp classify({:no_ticket, _}), do: "could not mint a ticket (TCP to /ws-ticket failed)"
  defp classify(:econnrefused), do: "TCP connection refused (listen backlog full)"
  defp classify(:emfile), do: "out of file descriptors"
  defp classify(%{__exception__: true} = e), do: "exception: #{inspect(e.__struct__)}"
  defp classify(other), do: "upgrade rejected: #{inspect(other) |> String.slice(0, 60)}"

  defp verdict(ok, clients, sent, expected, received, leaked) do
    cond do
      ok < clients ->
        IO.puts("VERDICT  #{clients - ok} sessions refused — see the reasons above")

      sent < expected ->
        IO.puts(
          "VERDICT  #{expected - sent} frames could not be sent — upstream backpressure fired"
        )

      leaked > 5 ->
        IO.puts(
          "VERDICT  #{leaked} processes left behind — something is not dying with its socket"
        )

      received < div(sent * 9, 10) ->
        IO.puts(
          "VERDICT  #{sent - received} frames shed downstream — the browser side fell behind"
        )

      true ->
        IO.puts("VERDICT  clean: every session connected, every frame went up and came back")
    end
  end

  defp pct(_n, 0), do: ""
  defp pct(n, total), do: "  (#{Float.round(n * 100 / total, 1)}%)"
  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)
  defp kb(bytes), do: Float.round(bytes / 1_024, 1)

  defp snapshot do
    %{
      procs: length(Process.list()),
      total: :erlang.memory(:total),
      binary: :erlang.memory(:binary)
    }
  end

  # ---- plumbing ----------------------------------------------------------------

  defp ticket(port) do
    request =
      "POST /ws-ticket HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" <>
        "Origin: http://127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

    with {:ok, socket} <- :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000),
         :ok <- :gen_tcp.send(socket, request),
         response <- read_all(socket, ""),
         :ok <- :gen_tcp.close(socket),
         [_headers, json] <- String.split(response, "\r\n\r\n", parts: 2),
         {:ok, %{"ticket" => ticket}} <- Jason.decode(json) do
      {:ok, ticket}
    else
      other -> {:error, {:no_ticket, other}}
    end
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> read_all(socket, acc <> chunk)
      {:error, _} -> acc
    end
  end

  defp start_apps do
    for app <- [:jason, :websockex, :bandit], do: {:ok, _} = Application.ensure_all_started(app)
    {:ok, _} = LiveCeci.Tickets.start_link([])
    {:ok, _} = LiveCeci.Sessions.start_link([])
  end

  defp start_server do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    # The accept backlog. ThousandIsland defaults to 1024 (transports/tcp.ex:22), and at
    # 5000 simultaneous connects the failures are all WebSockex.ConnError — TCP, not any
    # cap in this app — so the backlog looked like the obvious ceiling.
    #
    # It is not. Raising it to 16384 made things WORSE: 1155 refusals against 545 at the
    # default. A server-side limit would refuse a consistent number; that spread, in the
    # wrong direction, is noise. Past roughly 4000 clients this harness stops measuring
    # the server and starts measuring itself — client and server share one BEAM and one
    # machine, and 5000 of each plus their WebSockex processes saturate the CPU before
    # anything in lib/ notices.
    #
    # Kept as a knob because the refutation is worth being able to repeat.
    backlog = LiveCeci.env_int("LOAD_BACKLOG", 1_024, 128..65_535)

    {:ok, _pid} =
      Bandit.start_link(
        plug: LiveCeci.Router,
        port: port,
        ip: {127, 0, 0, 1},
        thousand_island_options: [transport_options: [backlog: backlog]]
      )

    port
  end

  defp sleep_until(deadline) do
    case deadline - now() do
      ms when ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end

Load.run()
