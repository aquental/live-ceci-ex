defmodule LiveCeci.Provider.GeminiTest do
  @moduledoc """
  The Gemini half of the seam: real `gemini_ex` structs in, neutral provider events
  out. These assertions used to live in `socket_test.exs`, back when the socket knew
  what a `ServerMessage` was.
  """
  use ExUnit.Case, async: true

  alias Gemini.Types.Live.{ServerContent, ServerMessage, ToolCall}
  alias LiveCeci.Provider.Gemini, as: Subject

  # 24 kHz PCM arrives base64-encoded inside the model turn's parts.
  @pcm <<1, 0, 2, 0, 3, 0, 255, 127>>

  defp audio_message(pcm) do
    %ServerMessage{
      server_content: %ServerContent{
        model_turn: %{
          role: "model",
          parts: [
            %{inline_data: %{"data" => Base.encode64(pcm), "mimeType" => "audio/pcm;rate=24000"}}
          ]
        }
      }
    }
  end

  describe "voice" do
    test "model audio is decoded before it leaves the provider" do
      Subject.translate(audio_message(@pcm), self())
      assert_received {:provider, {:voice, @pcm}}
    end

    test "several parts in one turn become several events, in order" do
      message = %ServerMessage{
        server_content: %ServerContent{
          model_turn: %{
            role: "model",
            parts: [
              %{inline_data: %{"data" => Base.encode64(<<1, 0>>), "mimeType" => "audio/pcm"}},
              %{inline_data: %{"data" => Base.encode64(<<2, 0>>), "mimeType" => "audio/pcm"}}
            ]
          }
        }
      }

      Subject.translate(message, self())
      assert_received {:provider, {:voice, <<1, 0>>}}
      assert_received {:provider, {:voice, <<2, 0>>}}
    end

    test "a text-only part emits nothing — this agent speaks, it does not type" do
      message = %ServerMessage{
        server_content: %ServerContent{model_turn: %{role: "model", parts: [%{text: "hi"}]}}
      }

      Subject.translate(message, self())
      refute_received {:provider, _}
    end

    test "turn_complete alone is not forwarded" do
      Subject.translate(
        %ServerMessage{server_content: %ServerContent{turn_complete: true}},
        self()
      )

      refute_received {:provider, _}
    end

    test "setup_complete is not forwarded" do
      Subject.translate(
        %ServerMessage{setup_complete: %Gemini.Types.Live.SetupComplete{}},
        self()
      )

      refute_received {:provider, _}
    end
  end

  describe "barge-in" do
    test "interrupted becomes the neutral event" do
      Subject.translate(%ServerMessage{server_content: %ServerContent{interrupted: true}}, self())
      assert_received {:provider, :interrupted}
    end

    test "voice and interruption in the same message both come out" do
      message = put_in(audio_message(@pcm).server_content.interrupted, true)

      Subject.translate(message, self())
      assert_received {:provider, {:voice, @pcm}}
      assert_received {:provider, :interrupted}
    end
  end

  describe "transcripts" do
    test "input is tagged :user, output is tagged :ceci" do
      Subject.translate_transcript({:input, %{"text" => "play something"}}, self())
      assert_received {:provider, {:transcript, :user, "play something"}}

      Subject.translate_transcript({:output, %{"text" => "sure"}}, self())
      assert_received {:provider, {:transcript, :ceci, "sure"}}
    end

    test "empty transcripts are dropped rather than drawn as blank lines" do
      Subject.translate_transcript({:output, %{"text" => ""}}, self())
      refute_received {:provider, _}
    end
  end

  describe "session_opts/1" do
    # Characterization: this locks the shape a working session actually used. It
    # cannot prove the shape is right — only that nobody changed it by accident,
    # which compiles clean and passes every other test in this file.
    setup do
      opts =
        Subject.session_opts(
          owner: self(),
          model: "m",
          voice: "Aoede",
          language: "pt-BR",
          silence_duration_ms: 300
        )

      %{opts: opts}
    end

    test "audio only — she speaks, she does not type", %{opts: o} do
      assert o[:generation_config].response_modalities == ["AUDIO"]
    end

    test "the voice is whatever was configured", %{opts: o} do
      assert o[:generation_config].speech_config.voice_config.prebuilt_voice_config.voice_name ==
               "Aoede"
    end

    test "the language rides on speech_config", %{opts: o} do
      assert o[:generation_config].speech_config.language_code == "pt-BR"
    end

    test "no language means the key is absent, not null — the API rejects a null" do
      o = Subject.session_opts(owner: self(), model: "m", voice: "Aoede", language: nil)
      refute Map.has_key?(o[:generation_config].speech_config, :language_code)
    end

    test "turn detection carries the silence budget", %{opts: o} do
      # Leaving this unset used Google's default, which made short utterances feel
      # like a stall.
      aad = o[:realtime_input_config].automatic_activity_detection
      assert aad.silence_duration_ms == 300
      assert aad.end_of_speech_sensitivity == :high
    end

    test "the silence budget is the configured one, not a constant" do
      # Same guard as the Grok side: the knob has to reach the wire, and a hardcoded
      # value here would pass every other test in this block while .env did nothing.
      o =
        Subject.session_opts(owner: self(), model: "m", voice: "Aoede", silence_duration_ms: 250)

      assert o[:realtime_input_config].automatic_activity_detection.silence_duration_ms == 250
    end

    test "an omitted silence budget falls back rather than sending nil" do
      o = Subject.session_opts(owner: self(), model: "m", voice: "Aoede")

      assert o[:realtime_input_config].automatic_activity_detection.silence_duration_ms == 400
    end

    test "both transcription directions are on — the browser draws both", %{opts: o} do
      assert o[:input_audio_transcription] == %{}
      assert o[:output_audio_transcription] == %{}
    end

    test "the persona goes as the Content struct Gemini expects, not a string", %{opts: o} do
      assert %{parts: [%{text: text}]} = o[:system_instruction]
      assert text == LiveCeci.Persona.instruction()
    end

    test "every declared tool crosses over", %{opts: o} do
      assert [%{function_declarations: declarations}] = o[:tools]
      assert declarations == LiveCeci.Tools.declarations()
    end

    test "the callbacks the provider depends on are all wired", %{opts: o} do
      for key <- [:on_message, :on_transcription, :on_error, :on_close, :on_tool_call] do
        assert is_function(o[key]), "missing callback: #{key}"
      end
    end
  end

  describe "close/1" do
    test "tolerates an already-dead session" do
      # monitor/DOWN rather than Process.sleep. Same reasoning as the Grok side: sleeping
      # asserts that 20 ms is always enough, which is a claim about the machine.
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      refute Process.alive?(pid)
      assert :ok = Subject.close(%{session: pid, carrier: self()})
    end
  end

  describe "tool calls" do
    test "a tool call emits an action AND answers the model instantly" do
      tool_call = %ToolCall{
        function_calls: [
          %{id: "call_1", name: "emitir_recibo", args: %{"paciente" => "M.S.", "valor" => "250"}}
        ]
      }

      assert {:tool_response,
              [%{id: "call_1", name: "emitir_recibo", response: %{result: "recibo emitido"}}]} =
               Subject.handle_tool_call(tool_call, self())

      assert_received {:provider, {:action, %{action: "recibo", detail: "M.S. · R$ 250"}}}
    end

    test "several calls in one batch are all dispatched, in order" do
      tool_call = %ToolCall{
        function_calls: [
          %{
            id: "a",
            name: "confirmar_presenca",
            args: %{"paciente" => "R.L.", "status" => "faltou"}
          },
          %{id: "b", name: "resumo_mensal", args: %{"mes" => "agosto"}}
        ]
      }

      assert {:tool_response, [%{id: "a"}, %{id: "b"}]} =
               Subject.handle_tool_call(tool_call, self())

      assert_received {:provider, {:action, %{action: "presenca", detail: "R.L. · faltou"}}}
      assert_received {:provider, {:action, %{action: "resumo", detail: "agosto"}}}
    end

    test "an unknown tool still answers the model, but emits no action" do
      tool_call = %ToolCall{function_calls: [%{id: "x", name: "teleport", args: %{}}]}

      assert {:tool_response, [%{id: "x", response: %{result: "unknown tool: teleport"}}]} =
               Subject.handle_tool_call(tool_call, self())

      refute_received {:provider, {:action, _command}}
    end

    test "nil args do not crash the turn" do
      tool_call = %ToolCall{function_calls: [%{id: "y", name: "resumo_mensal", args: nil}]}
      assert {:tool_response, [%{id: "y"}]} = Subject.handle_tool_call(tool_call, self())
    end
  end
end
