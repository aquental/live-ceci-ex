defmodule LiveCeci.Provider.GrokTest do
  @moduledoc """
  The Grok half of the seam: real xAI Voice Agent events in, neutral provider events
  out. The event shapes here are the ones the spike in `priv/spike/` saw on the wire,
  not invented ones.

  `translate/2` is private, so these go through `handle_frame/2` — which is also what
  the live socket exercises, and it catches a mistake the direct call would not: the
  frames a tool call has to send back cannot go out through `WebSockex.send_frame/3`
  from this process, so `handle_frame/2` must hand them to `handle_cast/2` instead.
  """
  use ExUnit.Case, async: true

  alias LiveCeci.Provider.Grok

  @pcm <<1, 0, 2, 0, 3, 0, 255, 127>>

  defp state, do: %{owner: self()}
  defp frame(event), do: Grok.handle_frame({:text, Jason.encode!(event)}, state())

  describe "voice" do
    test "a binary frame is voice, passed through untouched" do
      # This is the normal path: the session negotiates transport: "binary", so audio
      # never gets base64-wrapped in either direction.
      assert {:ok, _state} = Grok.handle_frame({:binary, @pcm}, state())
      assert_received {:provider, {:voice, @pcm}}
    end

    test "a base64 delta still works, in case the server ignores the transport request" do
      assert {:ok, _state} =
               frame(%{type: "response.output_audio.delta", delta: Base.encode64(@pcm)})

      assert_received {:provider, {:voice, @pcm}}
    end

    test "an undecodable delta is dropped rather than crashing the connection" do
      assert {:ok, _state} = frame(%{type: "response.output_audio.delta", delta: "not base64!!"})
      refute_received {:provider, _}
    end
  end

  describe "barge-in" do
    test "input_speech.started is the interruption signal" do
      # Gemini reports the effect (`interrupted`); Grok reports the cause. The socket
      # gets the same event either way.
      assert {:ok, _state} = frame(%{type: "input_speech.started"})
      assert_received {:provider, :interrupted}
    end
  end

  describe "transcripts" do
    test "input transcription is tagged :user" do
      assert {:ok, _state} =
               frame(%{
                 type: "conversation.item.input_audio_transcription.updated",
                 transcript: "toca uma musica"
               })

      assert_received {:provider, {:transcript, :user, "toca uma musica"}}
    end

    test "output transcription is tagged :mira" do
      assert {:ok, _state} =
               frame(%{type: "response.output_audio_transcript.done", transcript: "claro"})

      assert_received {:provider, {:transcript, :mira, "claro"}}
    end

    test "an empty transcript is dropped rather than drawn as a blank line" do
      assert {:ok, _state} =
               frame(%{
                 type: "conversation.item.input_audio_transcription.updated",
                 transcript: ""
               })

      refute_received {:provider, _}
    end
  end

  describe "tool calls" do
    test "a tool call emits a play command for the browser" do
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "play_playlist",
                 call_id: "call_1",
                 arguments: ~s({"mood":"dream pop"})
               })

      assert_received {:provider, {:play, %{action: "playlist", value: "dream pop"}}}
    end

    test "the result goes back as two casts, because one message is not enough" do
      # conversation.item.create carries the answer; response.create is what makes the
      # model start speaking again. Sending only the first leaves it silent.
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "skip",
                 call_id: "call_2",
                 arguments: "{}"
               })

      assert_received {:"$websockex_cast", {:send, %{type: "conversation.item.create"} = item}}
      assert item.item.call_id == "call_2"
      assert item.item.type == "function_call_output"
      assert_received {:"$websockex_cast", {:send, %{type: "response.create"}}}
    end

    test "an unknown tool still answers the model, but emits no play command" do
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "teleport",
                 call_id: "call_3",
                 arguments: "{}"
               })

      refute_received {:provider, {:play, _}}
      assert_received {:"$websockex_cast", {:send, %{type: "conversation.item.create"}}}
    end

    test "malformed arguments degrade to an empty map rather than crashing the turn" do
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "play_playlist",
                 call_id: "call_4",
                 arguments: "{not json"
               })

      assert_received {:provider, {:play, %{action: "playlist", value: ""}}}
    end

    test "the reply is a cast, not a direct send_frame" do
      # WebSockex.send_frame/3 raises CallingSelfError when the caller is the socket
      # process, which handle_frame/2 is. This is the regression that guards it.
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "pause",
                 call_id: "call_5",
                 arguments: "{}"
               })

      assert_received {:"$websockex_cast", {:send, _}}
    end
  end

  describe "handle_cast/2" do
    test "turns a queued payload into an outgoing text frame" do
      assert {:reply, {:text, json}, _state} =
               Grok.handle_cast({:send, %{type: "response.create"}}, state())

      assert Jason.decode!(json) == %{"type" => "response.create"}
    end
  end

  describe "failure paths" do
    test "an error event reaches the socket" do
      assert {:ok, _state} = frame(%{type: "error", error: %{message: "nope"}})
      assert_received {:provider, {:error, %{"message" => "nope"}}}
    end

    test "a disconnect is reported as closed" do
      assert {:ok, _state} = Grok.handle_disconnect(%{reason: :normal}, state())
      assert_received {:provider, {:closed, :normal}}
    end

    test "unknown events are ignored rather than crashing the connection" do
      assert {:ok, _state} = frame(%{type: "conversation.created", conversation: %{id: "c1"}})
      refute_received {:provider, _}
    end

    test "an undecodable frame is ignored" do
      assert {:ok, _state} = Grok.handle_frame({:text, "not json at all"}, state())
      refute_received {:provider, _}
    end
  end

  describe "open/1" do
    test "refuses to open without a key rather than failing at connect time" do
      assert {:error, :missing_grok_api_key} =
               Grok.open(owner: self(), model: "m", voice: "v", api_key: "")
    end
  end
end
