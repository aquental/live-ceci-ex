defmodule LiveCeciTest do
  # async: false — these mutate :live_ceci application env, which every process shares.
  use ExUnit.Case, async: false

  describe "config/0" do
    test "reports the model, voice and port the app booted with" do
      assert %{model: model, voice: voice, port: port} = LiveCeci.config()

      assert is_binary(model) and model != ""
      assert is_binary(voice) and voice != ""
      # 0 is legitimate: config/test.exs asks the OS for an ephemeral port.
      assert is_integer(port) and port in 0..65535
    end

    # runtime.exs used to hardcode 8000 here instead of falling back to the configured
    # value the way model and voice do, which made config/test.exs unable to move the
    # port — so `mix test` died with :eaddrinuse whenever the dev server was running.
    test "the test env asks the OS for a port instead of fighting the dev server for 8000" do
      assert LiveCeci.config().port == 0
    end

    # The whole point of reading Application env here rather than freezing the values at
    # compile time: config/runtime.exs writes them at boot, from GOOGLE_API_KEY's
    # neighbours in .env. A memoized config/0 would silently ignore LIVE_MODEL and
    # LIVE_VOICE, and the failure would only show up as the wrong voice on a live call.
    test "reads the env at call time, so a boot-time override wins" do
      previous = Application.get_env(:live_ceci, :voice)
      on_exit(fn -> Application.put_env(:live_ceci, :voice, previous) end)

      Application.put_env(:live_ceci, :voice, "Charon")
      assert %{voice: "Charon"} = LiveCeci.config()

      Application.put_env(:live_ceci, :voice, "Puck")
      assert %{voice: "Puck"} = LiveCeci.config()
    end
  end

  describe "the test environment is sealed off from the machine" do
    # config/runtime.exs runs AFTER config/test.exs, so anything it reads from the
    # environment silently outranks what the test config declared. It used to read a
    # developer's .env in every environment, and two things leaked through:
    #
    #   PORT=8000            beat `config :live_ceci, port: 0`
    #   GOOGLE_API_KEY=...   beat `config :gemini_ex, api_key: "test-key"`,
    #                        so `mix test` ran with the real credential in app env
    #
    # Every assertion below pins an EXACT literal, on purpose. The tests that used to
    # cover these knobs asserted only type and range — `is_integer(silence) and silence
    # in 0..10_000` — and a leaked 300 satisfies that as happily as the default 400.
    # That is why the port was the only leak anyone noticed: it was the only one pinned.

    test "the API key is the test one, never a real credential from .env or the shell" do
      # The sharpest of these. A real key here means the suite is one accidental network
      # call away from spending someone's quota, and one inspect/1 away from logging it.
      #
      # The custom message is not decoration. A bare `assert key == "test-key"` prints
      # ExUnit's left/right diff on failure — which is to say it prints the real key, to
      # the terminal and to CI output. A test guarding against a leaked credential must
      # not be the thing that leaks it. Verified: this failure names the length, not
      # the key.
      key = Application.get_env(:gemini_ex, :api_key)

      assert key == "test-key",
             "the test env holds a #{byte_size(to_string(key))}-byte key that is not " <>
               "the test one — .env or the shell leaked a real credential into mix test"
    end

    test "the port comes from config/test.exs, so the suite never fights the dev server" do
      assert LiveCeci.config().port == 0
    end

    test "the voice, language and latency knobs are the compiled defaults" do
      # These differ from the values in the repo's own .env (luna / pt-BR / 300 / 1500),
      # which is exactly what makes them a leak detector rather than a tautology.
      assert %{
               voice: "eve",
               language: nil,
               silence_duration_ms: 400,
               frame_samples: 1600,
               turn_detection: :manual
             } = LiveCeci.config()
    end
  end

  describe "env_int/3" do
    setup do
      on_exit(fn -> System.delete_env("LIVE_CECI_TEST_INT") end)
    end

    defp put(value), do: System.put_env("LIVE_CECI_TEST_INT", value)
    defp read, do: LiveCeci.env_int("LIVE_CECI_TEST_INT", 400, 0..10_000)

    test "an unset variable is the default, silently — that is not an error" do
      System.delete_env("LIVE_CECI_TEST_INT")
      assert read() == 400
    end

    test "an empty variable is the default too — .env writes KEY= for a cleared value" do
      put("")
      assert read() == 400
    end

    test "a valid integer wins, surrounding whitespace and all" do
      put("300")
      assert read() == 300

      put("  250  ")
      assert read() == 250
    end

    test "the range bounds are inclusive" do
      put("0")
      assert read() == 0

      put("10000")
      assert read() == 10_000
    end

    # The reason this function exists instead of String.to_integer/1. Every one of these
    # is a plausible .env typo, and each would otherwise either crash the boot or — worse
    # — quietly revert to the default and invalidate whatever benchmark run was meant to
    # justify the number.
    test "garbage falls back to the default AND says so, rather than failing silently" do
      for bad <- ["30O", "abc", "3.5", "300ms", "-1", "10001", "1e3"] do
        put(bad)

        assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
                 assert read() == 400
               end) =~ "LIVE_CECI_TEST_INT"
      end
    end
  end

  describe "normalize_language/1" do
    # .env carries the POSIX spelling a shell locale uses; Gemini's languageCode and
    # xAI's language_hint both want BCP-47.
    test "POSIX underscores become BCP-47 hyphens, with the region upper-cased" do
      assert LiveCeci.normalize_language("pt_BR") == "pt-BR"
      assert LiveCeci.normalize_language("es_mx") == "es-MX"
      assert LiveCeci.normalize_language("PT-br") == "pt-BR"
    end

    test "a bare language stays bare" do
      assert LiveCeci.normalize_language("en") == "en"
      assert LiveCeci.normalize_language("JA") == "ja"
    end

    test "unset means unset, not empty — the field is omitted rather than sent null" do
      assert LiveCeci.normalize_language(nil) == nil
      assert LiveCeci.normalize_language("") == nil
    end
  end
end
