defmodule LiveDJ.SocketTest do
  @moduledoc """
  The bridge, tested at the message-translation level: real `gemini_ex` structs in,
  real WebSocket frames out. No browser automation, no live session — the seam is
  `handle_info/2` and `handle_tool_call/2`, which is where every wire-contract bug
  the frontend can see actually lives.
  """
  use ExUnit.Case, async: true

  alias Gemini.Types.Live.{ServerContent, ServerMessage, ToolCall}
  alias LiveDJ.Socket

  # 24 kHz PCM arrives base64-encoded inside the model turn's parts.
  @pcm <<1, 0, 2, 0, 3, 0, 255, 127>>

  defp state, do: %{session: nil}

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

  describe "voice downstream" do
    test "model audio is decoded and pushed as a binary frame" do
      assert {:push, [{:binary, pcm}], _state} =
               Socket.handle_info({:gemini, audio_message(@pcm)}, state())

      assert pcm == @pcm
    end

    test "several parts in one turn become several frames, in order" do
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

      assert {:push, [{:binary, <<1, 0>>}, {:binary, <<2, 0>>}], _state} =
               Socket.handle_info({:gemini, message}, state())
    end

    test "a text-only part pushes nothing — this agent speaks, it does not type" do
      message = %ServerMessage{
        server_content: %ServerContent{model_turn: %{role: "model", parts: [%{text: "hi"}]}}
      }

      assert {:ok, _state} = Socket.handle_info({:gemini, message}, state())
    end

    test "turn_complete alone is not forwarded" do
      message = %ServerMessage{server_content: %ServerContent{turn_complete: true}}
      assert {:ok, _state} = Socket.handle_info({:gemini, message}, state())
    end

    test "setup_complete is not forwarded" do
      message = %ServerMessage{setup_complete: %Gemini.Types.Live.SetupComplete{}}
      assert {:ok, _state} = Socket.handle_info({:gemini, message}, state())
    end
  end

  describe "barge-in" do
    test "interrupted becomes the JSON the frontend cuts playback on" do
      message = %ServerMessage{server_content: %ServerContent{interrupted: true}}

      assert {:push, [{:text, json}], _state} = Socket.handle_info({:gemini, message}, state())
      assert Jason.decode!(json) == %{"type" => "interrupted"}
    end

    test "voice and interruption in the same message both go out" do
      message = put_in(audio_message(@pcm).server_content.interrupted, true)

      assert {:push, [{:binary, _pcm}, {:text, json}], _state} =
               Socket.handle_info({:gemini, message}, state())

      assert Jason.decode!(json) == %{"type" => "interrupted"}
    end
  end

  describe "transcripts" do
    test "input transcription is labelled as the user" do
      assert {:push, [{:text, json}], _state} =
               Socket.handle_info(
                 {:transcription, {:input, %{"text" => "play something"}}},
                 state()
               )

      assert %{"type" => "transcript", "role" => "user", "text" => "play something"} =
               Jason.decode!(json)
    end

    test "output transcription is labelled as mira" do
      assert {:push, [{:text, json}], _state} =
               Socket.handle_info({:transcription, {:output, %{"text" => "sure"}}}, state())

      assert %{"type" => "transcript", "role" => "mira", "text" => "sure"} = Jason.decode!(json)
    end

    test "empty transcripts are dropped rather than drawn as blank lines" do
      assert {:ok, _state} =
               Socket.handle_info({:transcription, {:output, %{"text" => ""}}}, state())
    end
  end

  describe "tool calls" do
    test "a play_playlist call sends the browser a command AND answers the model instantly" do
      tool_call = %ToolCall{
        function_calls: [%{id: "call_1", name: "play_playlist", args: %{"mood" => "dream pop"}}]
      }

      assert {:tool_response, [%{id: "call_1", name: "play_playlist", response: %{result: "ok"}}]} =
               Socket.handle_tool_call(tool_call, self())

      assert_received {:play, %{action: "playlist", value: "dream pop"}}
    end

    test "several calls in one batch are all dispatched, in order" do
      tool_call = %ToolCall{
        function_calls: [
          %{id: "a", name: "play_playlist", args: %{"mood" => "lofi"}},
          %{id: "b", name: "skip", args: %{}}
        ]
      }

      assert {:tool_response, [%{id: "a"}, %{id: "b"}]} =
               Socket.handle_tool_call(tool_call, self())

      assert_received {:play, %{action: "playlist", value: "lofi"}}
      assert_received {:play, %{action: "skip"}}
    end

    test "an unknown tool still answers the model, but emits no play command" do
      tool_call = %ToolCall{function_calls: [%{id: "x", name: "teleport", args: %{}}]}

      assert {:tool_response, [%{id: "x", response: %{result: "unknown tool: teleport"}}]} =
               Socket.handle_tool_call(tool_call, self())

      refute_received {:play, _command}
    end

    test "nil args do not crash the turn" do
      tool_call = %ToolCall{function_calls: [%{id: "y", name: "skip", args: nil}]}
      assert {:tool_response, [%{id: "y"}]} = Socket.handle_tool_call(tool_call, self())
    end

    test "the play command reaches the browser as the frontend's play message" do
      assert {:push, [{:text, json}], _state} =
               Socket.handle_info({:play, %{action: "track", value: "porcelain"}}, state())

      assert %{"type" => "play", "action" => "track", "value" => "porcelain"} =
               Jason.decode!(json)
    end
  end

  describe "failure paths" do
    test "a session error is reported to the browser instead of dying silently" do
      assert {:push, [{:text, json}], _state} =
               Socket.handle_info({:gemini_error, :boom}, state())

      assert %{"type" => "error", "message" => ":boom"} = Jason.decode!(json)
    end

    test "a closed session stops the socket normally" do
      assert {:stop, :normal, _state} = Socket.handle_info({:gemini_closed, :normal}, state())
    end

    test "a crashed session process stops the socket instead of taking it down silently" do
      pid = self()
      assert {:stop, :normal, _state} = Socket.handle_info({:EXIT, pid, :killed}, %{session: pid})
    end

    test "unknown messages are ignored" do
      assert {:ok, _state} = Socket.handle_info(:something_else, state())
    end
  end

  describe "upstream" do
    test "text frames are accepted and ignored — the contract reserves them" do
      assert {:ok, _state} = Socket.handle_in({~s({"type":"start"}), [opcode: :text]}, state())
    end
  end
end
