defmodule LiveDJ do
  @moduledoc """
  live-dj — a voice agent you can interrupt.

  Talk to Mira, a late-night radio DJ. Ask her to play something. Talk over her
  mid-sentence and she stops, listens, and picks the thread back up.

  Built on the Gemini Live API via `gemini_ex` — no agent framework, no Phoenix,
  so the whole primitive stays visible. An Elixir port of the EP1 demo from the
  Multimodal Agents Cookbook.

  The pieces:

    * `LiveDJ.Socket`  — the bridge: one browser socket, one Live session
    * `LiveDJ.Tools`   — the music-control function calls (they return instantly)
    * `LiveDJ.Persona` — who Mira is
    * `LiveDJ.Router`  — the WebSocket upgrade + static files
  """

  @doc """
  Runtime configuration: the Live model, Mira's native voice, and the HTTP port.
  """
  @spec config() :: %{model: String.t(), voice: String.t(), port: pos_integer()}
  def config do
    %{
      model: Application.get_env(:live_dj, :model),
      voice: Application.get_env(:live_dj, :voice),
      port: Application.get_env(:live_dj, :port)
    }
  end
end
