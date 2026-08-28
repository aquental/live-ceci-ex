defmodule LiveDJTest do
  # async: false — these mutate :live_dj application env, which every process shares.
  use ExUnit.Case, async: false

  describe "config/0" do
    test "reports the model, voice and port the app booted with" do
      assert %{model: model, voice: voice, port: port} = LiveDJ.config()

      assert is_binary(model) and model != ""
      assert is_binary(voice) and voice != ""
      # 0 is legitimate: config/test.exs asks the OS for an ephemeral port.
      assert is_integer(port) and port in 0..65535
    end

    # runtime.exs used to hardcode 8000 here instead of falling back to the configured
    # value the way model and voice do, which made config/test.exs unable to move the
    # port — so `mix test` died with :eaddrinuse whenever the dev server was running.
    test "the test env asks the OS for a port instead of fighting the dev server for 8000" do
      assert LiveDJ.config().port == 0
    end

    # The whole point of reading Application env here rather than freezing the values at
    # compile time: config/runtime.exs writes them at boot, from GOOGLE_API_KEY's
    # neighbours in .env. A memoized config/0 would silently ignore LIVE_MODEL and
    # LIVE_VOICE, and the failure would only show up as the wrong voice on a live call.
    test "reads the env at call time, so a boot-time override wins" do
      previous = Application.get_env(:live_dj, :voice)
      on_exit(fn -> Application.put_env(:live_dj, :voice, previous) end)

      Application.put_env(:live_dj, :voice, "Charon")
      assert %{voice: "Charon"} = LiveDJ.config()

      Application.put_env(:live_dj, :voice, "Puck")
      assert %{voice: "Puck"} = LiveDJ.config()
    end
  end

  describe "normalize_language/1" do
    # .env carries the POSIX spelling a shell locale uses; Gemini's languageCode and
    # xAI's language_hint both want BCP-47.
    test "POSIX underscores become BCP-47 hyphens, with the region upper-cased" do
      assert LiveDJ.normalize_language("pt_BR") == "pt-BR"
      assert LiveDJ.normalize_language("es_mx") == "es-MX"
      assert LiveDJ.normalize_language("PT-br") == "pt-BR"
    end

    test "a bare language stays bare" do
      assert LiveDJ.normalize_language("en") == "en"
      assert LiveDJ.normalize_language("JA") == "ja"
    end

    test "unset means unset, not empty — the field is omitted rather than sent null" do
      assert LiveDJ.normalize_language(nil) == nil
      assert LiveDJ.normalize_language("") == nil
    end
  end
end
