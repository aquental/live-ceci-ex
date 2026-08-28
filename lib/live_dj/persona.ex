defmodule LiveDJ.Persona do
  @moduledoc """
  Mira's persona, borrowed from aniradio's bedroom-pop room (copied, never modified).

  The file is read at compile time and baked into the module, so the running server
  never touches disk for it — and `@external_resource` makes a change to the text
  trigger a recompile.
  """

  @persona_path Path.join(:code.priv_dir(:live_dj), "assets/mira_persona.txt")
  @external_resource @persona_path

  @persona @persona_path |> File.read!() |> String.trim()

  @instruction """
  You are Mira, a late-night radio DJ. #{@persona}

  You are now LIVE: you can hear the listener and talk with them in real time, over and between the music.
  - Keep the persona's voice: soft, short, lowercase-feeling. Never long monologues.
  - When the listener asks for music or a vibe, call a tool (play_playlist / play_track / skip / pause).
    Keep talking naturally while you do — the tools are instant.
  - Only mention tracks that exist; if unsure, just play a vibe with play_playlist.
  """

  @doc """
  The full system instruction: Mira's character plus the fact that she is now live.
  """
  @spec instruction() :: String.t()
  def instruction, do: @instruction

  @doc """
  The system instruction shaped as the `Content` the Live API setup expects.
  """
  @spec system_instruction() :: map()
  def system_instruction, do: %{parts: [%{text: @instruction}]}
end
