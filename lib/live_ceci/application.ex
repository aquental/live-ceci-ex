defmodule LiveCeci.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:live_ceci, :port, 8000)
    bind_ip = Application.get_env(:live_ceci, :bind_ip, {127, 0, 0, 1})

    children = [
      # Before Bandit: the ticket table has to exist before the first upgrade can ask
      # about it.
      LiveCeci.Tickets,
      {
        Bandit,
        # ThousandIsland defaults to send_timeout: 30_000 (transports/tcp.ex:24). Thirty
        # seconds is a long time to hold this connection's process inside one write — and
        # while it is held, every provider event keeps arriving as a plain send/2, which
        # never blocks the sender. So a browser that stops reading grows this mailbox
        # unbounded for half a minute. Five seconds, then send_timeout_close drops it.
        plug: LiveCeci.Router,
        port: port,
        ip: bind_ip,
        thousand_island_options: [transport_options: [send_timeout: 5_000]]
      }
    ]

    Logger.info("live-ceci listening on http://#{:inet.ntoa(bind_ip)}:#{port} — headphones on")

    # One-for-one: each browser socket is its own process under Bandit's own
    # supervision tree, so one dropped call never touches another listener.
    Supervisor.start_link(children, strategy: :one_for_one, name: LiveCeci.Supervisor)
  end
end
