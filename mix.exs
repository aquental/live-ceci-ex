defmodule LiveCeci.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_ceci,
      version: "0.1.0",
      # Matches .tool-versions, which is what CI builds with. It was "~> 1.17": an honest
      # floor when it was written, and by now a stale one that lets a contributor on an
      # older toolchain pass the check locally while CI builds strictly on 1.20.4.
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      # :crypto is used directly by LiveCeci.Tickets for strong_rand_bytes/1. It worked
      # without being declared only because something else in the tree starts it — an
      # implicit invariant, in a project that has already had a dependency swap its
      # transport once.
      extra_applications: [:logger, :crypto],
      mod: {LiveCeci.Application, []}
    ]
  end

  # test/support holds helpers shared across test files, compiled only for :test.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # the HTTP server + the raw WebSocket upgrade. No Phoenix: the contract here is
      # binary PCM frames, which Channels would only wrap in a JSON envelope.
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.18"},
      # The WebSocket CLIENT. Already in the tree via gemini_ex, but LiveCeci.Provider.Grok
      # uses it directly — there is no Elixir package for the OpenAI Realtime protocol
      # xAI speaks, so that transport is hand-rolled.
      {:websockex, "~> 0.5.1"},
      {:websock_adapter, "~> 0.6.0"},
      # Used directly — LiveCeci.Socket declares `@behaviour WebSock` — but it used to
      # arrive only through websock_adapter. A behaviour you implement is a dependency
      # you have; leaving it transitive means a resolver is free to move it under you.
      {:websock, "~> 0.5.3"},

      # Gemini Live API — Gemini.Live.Session is a GenServer over the Bidi WebSocket.
      # Pinned to the minor: "~> 0.17" would allow anything under 1.0, and 0.16.0 already
      # swapped the Live WebSocket transport once. LiveCeci.Socket pattern-matches
      # Gemini.Types.Live.* in function heads, so drift is a runtime error, not a compile one.
      {:gemini_ex, "~> 0.17.0"},
      {:jason, "~> 1.4"},

      # mix hex.audit only reads maintainer retirement flags; this checks the advisory DB.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end
end
