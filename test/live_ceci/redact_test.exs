defmodule LiveCeci.RedactTest do
  # async: false — sets :gemini_ex api_key, which is global.
  use ExUnit.Case, async: false

  alias LiveCeci.Redact

  @key "AQ.Ab8RealLookingKey123456"

  setup do
    previous = Application.get_env(:gemini_ex, :api_key)
    Application.put_env(:gemini_ex, :api_key, @key)
    on_exit(fn -> Application.put_env(:gemini_ex, :api_key, previous) end)
    :ok
  end

  describe "the shapes that actually leaked" do
    # Each of these was reproduced against the real reason terms before this module
    # existed. They are here as the record of what was wrong, not as invented examples.

    test "gemini_ex puts the key in the WebSocket URL, so an error quoting the URL quotes it" do
      reason = {:connection_down, {:tls_alert, ~c"connecting to wss://x/ws?key=#{@key}"}}

      out = Redact.inspect(reason)
      refute out =~ @key
      assert out =~ "key=[REDACTED]"
    end

    test "xAI echoes an invalid key straight back in the error message" do
      out = Redact.inspect({:http_error, 403, "API key not valid: #{@key}"})

      refute out =~ @key
      assert out =~ "[REDACTED]"
    end

    test "a bearer token in a header list" do
      out = Redact.inspect(%{extra_headers: [{"Authorization", "Bearer xai-abc123SECRETtoken"}]})

      refute out =~ "xai-abc123SECRETtoken"
      assert out =~ "Bearer [REDACTED]"
    end
  end

  describe "the two passes" do
    test "a known credential is caught by value, whatever shape it arrives in" do
      # The point of the exact pass: it does not care about vendor prefixes, so it cannot
      # go stale the week a provider changes its key format.
      for term <- [@key, {:a, @key}, %{k: @key}, [nested: [deep: @key]], "prefix#{@key}suffix"] do
        refute Redact.inspect(term) =~ @key, "leaked from #{inspect(term)}"
      end
    end

    test "an unknown credential is caught by context" do
      # The point of the contextual pass: a token this app never held and cannot compare
      # against — minted upstream, refreshed, whatever.
      out = Redact.inspect({:error, "https://api.example/v1?key=totally-unknown-secret-9999"})

      refute out =~ "totally-unknown-secret"
      assert out =~ "key=[REDACTED]"
    end

    test "the placeholder is not itself redacted a second time" do
      # redact_known/1 runs first and leaves "[REDACTED]"; the contextual pass used to
      # match "[REDACTED" inside it and emit "[REDACTED]]".
      out = Redact.inspect({:error, "url?key=#{@key}"})

      refute out =~ "[REDACTED]]"
      assert out =~ "key=[REDACTED]"
    end
  end

  describe "what it must not do" do
    test "ordinary text survives untouched" do
      # A redactor that blanks out diagnostics is one that gets removed.
      for term <- [
            {:closed, :normal},
            {:error, :timeout},
            %{queued: 41, dropped: 3},
            "the line dropped — tente de novo"
          ] do
        refute Redact.inspect(term) =~ "[REDACTED]"
      end
    end

    test "a short configured value is not treated as a secret" do
      # config/test.exs sets api_key: "test-key". Redacting a 8-character string would
      # blank out any log line that happened to contain it.
      Application.put_env(:gemini_ex, :api_key, "test-key")

      assert Redact.inspect({:error, "test-key was rejected"}) =~ "test-key"
    end
  end

  describe "the call sites" do
    test "nothing in lib/ logs a raw inspect of an upstream reason" do
      # The guard that matters more than any single case above: this module only helps at
      # the places that call it, and the leak was seven `inspect(reason)` sites in one
      # file. A new one compiles clean and says nothing until a key is in a log.
      # Scoped to Logger lines, and deliberately NOT to variable names.
      #
      # The first version matched three names (reason, msg, other), which the re-audit
      # rightly called too narrow. Widening it to every bare inspect/1 in lib/ was worse:
      # it flagged four files and not one was a leak — Redact's own `def inspect`, a
      # module name, a request header, an .env value. A guard that cries wolf gets
      # deleted rather than fixed, which is the lesson the "no lingering mira" grep
      # already taught in this codebase.
      #
      # So the rule is a shape, not a vocabulary: a Logger call may not inspect anything
      # itself. That is followable without judgement, and it is why router.ex and
      # socket.ex now route even module names and headers through Redact — uniform costs
      # nothing, since Redact leaves anything that is not a credential alone.
      #
      # What it still cannot see is the two-step form: build a string, log it later.
      # No textual rule catches that one, and pretending otherwise would be worse than
      # saying so here.
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.any?(fn line ->
            String.contains?(line, "Logger.") and
              Regex.match?(~r/(?<![.\w])inspect\(/, line)
          end)
        end)

      assert offenders == [],
             "raw inspect of an upstream term in: #{Enum.join(offenders, ", ")} — " <>
               "use LiveCeci.Redact.inspect/1"
    end
  end
end
