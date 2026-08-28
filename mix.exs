defmodule LiveDJ.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_dj,
      version: "0.1.0",
      elixir: "~> 1.17",
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

  defp deps do
    [
      # the HTTP server + the raw WebSocket upgrade. No Phoenix: the contract here is
      # binary PCM frames, which Channels would only wrap in a JSON envelope.
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.18"},
      # The WebSocket CLIENT. Already in the tree via gemini_ex, but LiveDJ.Provider.Grok
      # uses it directly — there is no Elixir package for the OpenAI Realtime protocol
      # xAI speaks, so that transport is hand-rolled.
      {:websockex, "~> 0.4"},
      {:websock_adapter, "~> 0.5"},

      # Gemini Live API — Gemini.Live.Session is a GenServer over the Bidi WebSocket.
      # Pinned to the minor: "~> 0.17" would allow anything under 1.0, and 0.16.0 already
      # swapped the Live WebSocket transport once. LiveDJ.Socket pattern-matches
      # Gemini.Types.Live.* in function heads, so drift is a runtime error, not a compile one.
      {:gemini_ex, "~> 0.17.0"},
      {:jason, "~> 1.4"},

      # mix hex.audit only reads maintainer retirement flags; this checks the advisory DB.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end
end
