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

  describe "config/0 latency knobs" do
    test "both knobs are present and inside the range runtime.exs accepts" do
      assert %{silence_duration_ms: silence, frame_samples: frame} = LiveCeci.config()

      assert is_integer(silence) and silence in 0..10_000
      assert is_integer(frame) and frame in 160..16_000
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
