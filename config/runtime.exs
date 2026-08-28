import Config

# A ten-line python-dotenv, so `.env` from the Python repo works unchanged and we
# skip a dependency. Real deployments set the environment directly; this only fills
# in variables that aren't already set.
env_file = Path.expand("../.env", __DIR__)

if File.exists?(env_file) do
  env_file
  |> File.stream!()
  |> Enum.each(fn line ->
    with trimmed <- String.trim(line),
         false <- trimmed == "" or String.starts_with?(trimmed, "#"),
         [key, value] <- String.split(trimmed, "=", parts: 2) do
      key = String.trim(key)
      value = value |> String.trim() |> String.trim(~s(")) |> String.trim("'")
      if System.get_env(key) == nil, do: System.put_env(key, value)
    end
  end)
end

# gemini_ex reads GEMINI_API_KEY; the Python repo's .env uses GOOGLE_API_KEY. Accept both.
api_key = System.get_env("GEMINI_API_KEY") || System.get_env("GOOGLE_API_KEY")

if api_key do
  config :gemini_ex, api_key: api_key
else
  if config_env() != :test do
    IO.warn("""
    No API key found. Set GOOGLE_API_KEY (or GEMINI_API_KEY) in .env or the environment.
    Get one from AI Studio — the Gemini Developer API, not Vertex.
    """)
  end
end

# SOCKET_HANDLER=minimal runs the ~30-line primitive instead of the full DJ.
socket_handler =
  case System.get_env("SOCKET_HANDLER") do
    "minimal" -> LiveDJ.Minimal
    _ -> LiveDJ.Socket
  end

config :live_dj,
  socket_handler: socket_handler,
  model: System.get_env("LIVE_MODEL") || Application.get_env(:live_dj, :model),
  voice: System.get_env("LIVE_VOICE") || Application.get_env(:live_dj, :voice),
  port: String.to_integer(System.get_env("PORT") || "8000")
