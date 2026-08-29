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
    test "input is tagged :user, output is tagged :mira" do
      Subject.translate_transcript({:input, %{"text" => "play something"}}, self())
      assert_received {:provider, {:transcript, :user, "play something"}}

      Subject.translate_transcript({:output, %{"text" => "sure"}}, self())
      assert_received {:provider, {:transcript, :mira, "sure"}}
    end

    test "empty transcripts are dropped rather than drawn as blank lines" do
      Subject.translate_transcript({:output, %{"text" => ""}}, self())
      refute_received {:provider, _}
    end
  end

  describe "tool calls" do
    test "a play_playlist call emits a command AND answers the model instantly" do
      tool_call = %ToolCall{
        function_calls: [%{id: "call_1", name: "play_playlist", args: %{"mood" => "dream pop"}}]
      }

      assert {:tool_response, [%{id: "call_1", name: "play_playlist", response: %{result: "ok"}}]} =
               Subject.handle_tool_call(tool_call, self())

      assert_received {:provider, {:play, %{action: "playlist", value: "dream pop"}}}
    end

    test "several calls in one batch are all dispatched, in order" do
      tool_call = %ToolCall{
        function_calls: [
          %{id: "a", name: "play_playlist", args: %{"mood" => "lofi"}},
          %{id: "b", name: "skip", args: %{}}
        ]
      }

      assert {:tool_response, [%{id: "a"}, %{id: "b"}]} =
               Subject.handle_tool_call(tool_call, self())

      assert_received {:provider, {:play, %{action: "playlist", value: "lofi"}}}
      assert_received {:provider, {:play, %{action: "skip"}}}
    end

    test "an unknown tool still answers the model, but emits no play command" do
      tool_call = %ToolCall{function_calls: [%{id: "x", name: "teleport", args: %{}}]}

      assert {:tool_response, [%{id: "x", response: %{result: "unknown tool: teleport"}}]} =
               Subject.handle_tool_call(tool_call, self())

      refute_received {:provider, {:play, _command}}
    end

    test "nil args do not crash the turn" do
      tool_call = %ToolCall{function_calls: [%{id: "y", name: "skip", args: nil}]}
      assert {:tool_response, [%{id: "y"}]} = Subject.handle_tool_call(tool_call, self())
    end
  end
end
