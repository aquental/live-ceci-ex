defmodule LiveCeci do
  @moduledoc """
  live-ceci — a voice agent you can interrupt.

  Talk to Mira, a late-night radio DJ. Ask her to play something. Talk over her
  mid-sentence and she stops, listens, and picks the thread back up.

  Built on the Gemini Live API via `gemini_ex` — no agent framework, no Phoenix,
  so the whole primitive stays visible. An Elixir port of the EP1 demo from the
  Multimodal Agents Cookbook.

  The pieces:

    * `LiveCeci.Socket`  — the bridge: one browser socket, one Live session
    * `LiveCeci.Tools`   — the music-control function calls (they return instantly)
    * `LiveCeci.Persona` — who Mira is
    * `LiveCeci.Router`  — the WebSocket upgrade + static files
  """

  @doc """
  Runtime configuration: the Live model, Mira's native voice, and the HTTP port.
  """
  @spec config() :: %{
          model: String.t(),
          voice: String.t(),
          language: String.t(),
          port: pos_integer()
        }
  def config do
    %{
      model: Application.get_env(:live_ceci, :model),
      voice: Application.get_env(:live_ceci, :voice),
      language: Application.get_env(:live_ceci, :language),
      port: Application.get_env(:live_ceci, :port)
    }
  end

  @doc """
  Normalises a locale to the BCP-47 spelling both providers want.

  `.env` carries POSIX-style `pt_BR`, which is what a shell locale looks like, but
  Gemini's `languageCode` and xAI's `language_hint` both want `pt-BR`. Region is
  upper-cased and the language lower-cased, so `PT_br` lands in the same place.
  """
  @spec normalize_language(String.t() | nil) :: String.t() | nil
  def normalize_language(nil), do: nil
  def normalize_language(""), do: nil

  def normalize_language(locale) when is_binary(locale) do
    case locale |> String.replace("_", "-") |> String.split("-", parts: 2) do
      [lang] -> String.downcase(lang)
      [lang, region] -> String.downcase(lang) <> "-" <> String.upcase(region)
    end
  end
end
