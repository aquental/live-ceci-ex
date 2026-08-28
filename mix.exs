defmodule LiveDJ.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_dj,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LiveDJ.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # the HTTP server + the raw WebSocket upgrade. No Phoenix: the contract here is
      # binary PCM frames, which Channels would only wrap in a JSON envelope.
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.18"},
      {:websock_adapter, "~> 0.5"},

      # Gemini Live API — Gemini.Live.Session is a GenServer over the Bidi WebSocket.
      {:gemini_ex, "~> 0.17"},
      {:jason, "~> 1.4"}
    ]
  end
end
