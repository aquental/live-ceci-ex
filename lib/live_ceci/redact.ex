defmodule LiveCeci.Redact do
  @moduledoc """
  `inspect/1` for anything that might have touched a credential.

  Every upstream error reason in this app arrives from a library that was handed an API
  key, and two of them put it somewhere the reason can reach:

    * `gemini_ex` builds its WebSocket URL as `...?key=<the key>`, so a connection error
      that quotes the URL quotes the key with it.
    * xAI answers an invalid key with `"API key not valid: <the key>"`, echoing it back.

  Both were reproduced before this module existed. `LiveCeci.Socket` logs `reason` at
  seven sites, so any of them could put a live credential in the application log, where
  it outlives the session, gets shipped to whatever aggregates logs, and is read by
  people who never had access to the key.

  ## Two passes, and the order matters

  The first pass redacts the credentials this app KNOWS about, by exact value. It cannot
  be fooled by a format nobody predicted, because it is not matching a format — it is
  matching the string that is actually secret.

  The second pass catches the rest by context: whatever follows `key=`, `Bearer `,
  `api_key:` and friends. It exists for the credential this app does not hold — a
  refresh token, an ephemeral key minted upstream — where there is nothing to compare
  against.

  Neither pass is enough alone. Vendor prefixes (`AIza`, `AQ.`, `xai-`) are deliberately
  NOT the mechanism: they go stale the week a provider changes its format, and a redactor
  that quietly stops working is worse than none, because nothing tells you.
  """

  # Below this, a "secret" is either empty or something like "test-key", and redacting it
  # would blank out ordinary text without protecting anything.
  @min_secret_length 12

  @placeholder "[REDACTED]"

  # Context patterns, for credentials this app never sees. The value is whatever runs to
  # the next delimiter — quote, ampersand, whitespace, or the end.
  # `[` is excluded from every value class so a second pass cannot chew on the first
  # pass's own placeholder — without it, redact_known/1 leaving "[REDACTED]" made
  # redact_contextual/1 match "[REDACTED" and emit "[REDACTED]]". No key contains it.
  @contextual [
    ~r/(?<=[?&]key=)[^&"\s\[\]}]+/,
    ~r/(?<=[Bb]earer )[^"\s\[\]}]+/,
    ~r/(?<=api[_-]?key["':= ]{1,4})[A-Za-z0-9._\-]{#{@min_secret_length},}/,
    ~r/(?<=access[_-]?token["':= ]{1,4})[A-Za-z0-9._\-]{#{@min_secret_length},}/
  ]

  @doc """
  Inspects `term` and removes any credential from the result.

  Use this instead of `Kernel.inspect/1` for anything that came back from a provider.
  """
  @spec inspect(term()) :: String.t()
  def inspect(term) do
    term
    |> Kernel.inspect(limit: 8, printable_limit: 512)
    |> scrub()
  end

  @doc """
  Removes credentials from an already-rendered string.
  """
  @spec scrub(String.t()) :: String.t()
  def scrub(text) when is_binary(text) do
    text
    |> redact_known()
    |> redact_contextual()
  end

  # ---------------------------------------------------------------- private

  defp redact_known(text) do
    Enum.reduce(secrets(), text, fn secret, acc ->
      String.replace(acc, secret, @placeholder)
    end)
  end

  defp redact_contextual(text) do
    Enum.reduce(@contextual, text, fn pattern, acc ->
      Regex.replace(pattern, acc, @placeholder)
    end)
  end

  # Read at call time rather than cached. This runs on error paths, never on the audio
  # path, so the lookup costs nothing that matters — and a cached copy would be one more
  # place the key lives.
  defp secrets do
    [
      Application.get_env(:gemini_ex, :api_key),
      System.get_env("GROK_API_KEY"),
      System.get_env("GOOGLE_API_KEY"),
      System.get_env("GEMINI_API_KEY")
    ]
    |> Enum.filter(&(is_binary(&1) and String.length(&1) >= @min_secret_length))
    |> Enum.uniq()
    # Longest first: if one key is a prefix of another, redacting the short one first
    # would leave the tail of the long one in the output.
    |> Enum.sort_by(&byte_size/1, :desc)
  end
end
