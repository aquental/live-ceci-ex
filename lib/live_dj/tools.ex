defmodule LiveDJ.Tools do
  @moduledoc """
  Music-control tools for Mira.

  The whole lesson of these tools: in a live session, function calls are SYNCHRONOUS —
  the model's voice pauses until the tool returns. So each handler does the minimum
  (decide a "play" command for the browser) and returns INSTANTLY. It never awaits playback.

  That is why `dispatch/2` is a plain function over plain data: no GenServer call, no
  HTTP, no `Task.await`. If it ever needs to become one of those, the voice will stall.
  """

  @declarations [
    %{
      name: "play_playlist",
      description:
        "Start playing music of a given vibe or mood (e.g. 'dream pop', 'lofi', 'chill').",
      parameters: %{
        type: "object",
        properties: %{mood: %{type: "string", description: "the vibe to play"}},
        required: ["mood"]
      }
    },
    %{
      name: "play_track",
      description: "Play a specific track by its title.",
      parameters: %{
        type: "object",
        properties: %{title: %{type: "string", description: "the track title"}},
        required: ["title"]
      }
    },
    %{
      name: "skip",
      description: "Skip to the next track.",
      parameters: %{type: "object", properties: %{}}
    },
    %{
      name: "pause",
      description: "Pause or resume the music.",
      parameters: %{type: "object", properties: %{}}
    }
  ]

  @doc """
  The function declarations, shaped for the Live API `setup.tools` field.
  """
  @spec declarations() :: [map()]
  def declarations, do: @declarations

  @doc """
  The `tools` value for `Gemini.Live.Session.start_link/1`.
  """
  @spec live_tools() :: [map()]
  def live_tools, do: [%{function_declarations: @declarations}]

  @typedoc "A command the server forwards to the browser's music player, or `nil`."
  @type play_command :: %{required(:action) => String.t(), optional(:value) => String.t()} | nil

  @doc """
  Returns `{play_command, function_result}`.

  `play_command` is forwarded to the browser as `{"type": "play", ...}`.
  `function_result` is handed straight back to the model — instantly, never blocking.
  """
  @spec dispatch(String.t(), map()) :: {play_command(), map()}
  def dispatch("play_playlist", args),
    do: {%{action: "playlist", value: arg(args, "mood")}, %{result: "ok"}}

  def dispatch("play_track", args),
    do: {%{action: "track", value: arg(args, "title")}, %{result: "ok"}}

  def dispatch("skip", _args), do: {%{action: "skip"}, %{result: "ok"}}
  def dispatch("pause", _args), do: {%{action: "pause"}, %{result: "ok"}}
  def dispatch(name, _args), do: {nil, %{result: "unknown tool: #{name}"}}

  defp arg(args, key) when is_map(args), do: args[key] || args[String.to_atom(key)] || ""
  defp arg(_args, _key), do: ""
end
