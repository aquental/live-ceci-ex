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

# PORT wins, then whatever config/{env}.exs set — same fallback the two above use.
# Hardcoding 8000 here made config/test.exs unable to move the port at all.
port =
  case System.get_env("PORT") do
    nil -> Application.get_env(:live_ceci, :port)
    value -> String.to_integer(value)
  end

# MODEL picks the backend. Read here rather than baked in at compile time, so
# switching providers is an .env edit and a restart.
{provider, model, voice} =
  case System.get_env("MODEL") |> to_string() |> String.upcase() do
    "GROK" ->
      {LiveCeci.Provider.Grok, System.get_env("GROK_LIVE_MODEL") || "grok-voice-latest",
       System.get_env("GROK_LIVE_VOICE") || "eve"}

    _ ->
      {LiveCeci.Provider.Gemini,
       System.get_env("GOOGLE_LIVE_MODEL") || Application.get_env(:live_ceci, :model),
       System.get_env("GOOGLE_LIVE_VOICE") || Application.get_env(:live_ceci, :voice)}
  end

config :live_ceci,
  provider: provider,
  model: model,
  voice: voice,
  # POSIX spelling in .env, BCP-47 on the wire. Both providers want the latter.
  language: LiveCeci.normalize_language(System.get_env("LANGUAGE")),
  port: port
