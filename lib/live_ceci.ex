defmodule LiveCeci do
  @moduledoc """
  live-ceci — a voice agent you can interrupt.

  Talk to Ceci, the operational assistant from ceci.pro: she takes the admin side of a
  therapy practice — scheduling, attendance, receipts, the accountant's summary — and
  leaves the clinical side alone. Talk over her mid-sentence and she stops, listens, and
  picks the thread back up.

  Built on the Gemini Live API via `gemini_ex` — no agent framework, no Phoenix,
  so the whole primitive stays visible.

  The pieces:

    * `LiveCeci.Socket`  — the bridge: one browser socket, one Live session
    * `LiveCeci.Tools`   — the four operational function calls (they return instantly)
    * `LiveCeci.Persona` — who Ceci is
    * `LiveCeci.Router`  — the WebSocket upgrade + static files
  """

  @doc """
  Runtime configuration: the Live model, Ceci's native voice, the HTTP port, and the
  two latency knobs.

  `:silence_duration_ms` and `:frame_samples` are the only settings here that exist to
  be *changed*: they are the two largest controllable terms in the delay between the
  end of an utterance and the first byte of Ceci's answer, and
  `priv/spike/latency_bench.exs` measures the effect of moving them.
  """
  @spec config() :: %{
          model: String.t(),
          voice: String.t(),
          language: String.t(),
          port: pos_integer(),
          silence_duration_ms: non_neg_integer(),
          frame_samples: pos_integer()
        }
  def config do
    %{
      model: Application.get_env(:live_ceci, :model),
      voice: Application.get_env(:live_ceci, :voice),
      language: Application.get_env(:live_ceci, :language),
      port: Application.get_env(:live_ceci, :port),
      silence_duration_ms: Application.get_env(:live_ceci, :silence_duration_ms),
      frame_samples: Application.get_env(:live_ceci, :frame_samples)
    }
  end

  @doc """
  Reads an integer environment variable, falling back to `default` and SAYING SO.

  The fallback is loud on purpose. Both call sites are latency knobs that exist to be
  tuned and then measured, and a silent revert to the default on `SILENCE_DURATION_MS=30O`
  — letter O — would not break anything, would not show up in a log, and would quietly
  invalidate whichever benchmark run was supposed to justify the number.
  """
  @spec env_int(String.t(), integer(), Range.t()) :: integer()
  def env_int(name, default, min..max//_) do
    case System.get_env(name) do
      blank when blank in [nil, ""] ->
        default

      raw ->
        case Integer.parse(String.trim(raw)) do
          {n, ""} when n >= min and n <= max ->
            n

          _ ->
            IO.warn(
              "#{name}=#{inspect(raw)} is not an integer in #{min}..#{max}; using #{default}"
            )

            default
        end
    end
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
