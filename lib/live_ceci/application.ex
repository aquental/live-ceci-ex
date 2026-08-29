defmodule LiveCeci.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:live_ceci, :port, 8000)

    children = [
      {Bandit, plug: LiveCeci.Router, port: port}
    ]

    Logger.info("live-ceci listening on http://localhost:#{port} — headphones on")

    # One-for-one: each browser socket is its own process under Bandit's own
    # supervision tree, so one dropped call never touches another listener.
    Supervisor.start_link(children, strategy: :one_for_one, name: LiveCeci.Supervisor)
  end
end
