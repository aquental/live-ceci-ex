import Config

# A ten-line dotenv reader, so a `.env` beside the project works and we skip a
# dependency for it. Real deployments set the environment directly; this only fills
# in variables that aren't already set.
#
# NEVER in :test. This file runs AFTER config/test.exs, so anything it puts in the
# environment silently outranks what the test config declared. Two things went wrong
# before the guard existed, both invisible until something asserted on them:
#
#   * PORT=8000 in .env overrode `config :live_ceci, port: 0`, which test.exs sets
#     precisely so the suite does not fight the dev server for a port.
#   * GOOGLE_API_KEY in .env overrode `config :gemini_ex, api_key: "test-key"`, so
#     `mix test` ran with the developer's REAL key sitting in application env.
#
# The rule underneath both: a test run must not depend on what is on the machine.
env_file = Path.expand("../.env", __DIR__)

if config_env() != :test and File.exists?(env_file) do
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

# gemini_ex reads GEMINI_API_KEY; AI Studio hands you a GOOGLE_API_KEY. Accept both.
#
# Skipped entirely in :test, not just when unset. Not loading .env is not enough on its
# own — an exported GOOGLE_API_KEY in the shell reaches here the same way, and the test
# environment has no business holding a real credential. config/test.exs owns the value.
if config_env() != :test do
  api_key = System.get_env("GEMINI_API_KEY") || System.get_env("GOOGLE_API_KEY")

  if api_key do
    config :gemini_ex, api_key: api_key
  else
    IO.warn("""
    No API key found. Set GOOGLE_API_KEY (or GEMINI_API_KEY) in .env or the environment.
    Get one from AI Studio — the Gemini Developer API, not Vertex.
    """)
  end
end

# PORT wins, then whatever config/{env}.exs set — same fallback the two above use.
# Hardcoding 8000 here made config/test.exs unable to move the port at all.
# Same guard: in :test the port comes from config/test.exs and nowhere else.
port =
  case config_env() != :test && System.get_env("PORT") do
    value when is_binary(value) -> String.to_integer(value)
    _ -> Application.get_env(:live_ceci, :port)
  end

# MODEL picks the backend. Read here rather than baked in at compile time, so
# switching providers is an .env edit and a restart. Each branch carries its own
# defaults: a shared default would have to belong to one of them, and then the other
# would silently inherit a model name that means nothing to it.
{provider, model, voice} =
  case System.get_env("MODEL") |> to_string() |> String.upcase() do
    "GOOGLE" ->
      {LiveCeci.Provider.Gemini,
       System.get_env("GOOGLE_LIVE_MODEL") || "gemini-3.1-flash-live-preview",
       System.get_env("GOOGLE_LIVE_VOICE") || "Aoede"}

    _ ->
      {LiveCeci.Provider.Grok, System.get_env("GROK_LIVE_MODEL") || "grok-voice-latest",
       System.get_env("GROK_LIVE_VOICE") || "eve"}
  end

# Loopback unless told otherwise. Bandit's own default is 0.0.0.0, which on a laptop on
# café wifi puts an unauthenticated WebSocket in front of a metered API on the open LAN:
# /ws has no origin check and no auth, and every frame it accepts spends the API key's
# quota. BIND_IP=0.0.0.0 is the deliberate opt-in for when you want a phone to reach it.
bind_ip =
  case System.get_env("BIND_IP") || "127.0.0.1" do
    address ->
      case :inet.parse_address(String.to_charlist(address)) do
        {:ok, parsed} ->
          parsed

        {:error, _} ->
          IO.warn("BIND_IP=#{inspect(address)} is not an IP address; using 127.0.0.1")
          {127, 0, 0, 1}
      end
  end

config :live_ceci,
  provider: provider,
  bind_ip: bind_ip,
  model: model,
  voice: voice,
  # POSIX spelling in .env, BCP-47 on the wire. Both providers want the latter.
  language: LiveCeci.normalize_language(System.get_env("LANGUAGE")),
  port: port,
  # How long a provider's VAD waits in silence before deciding the turn is over. It is
  # a hard floor under every answer — nothing comes back until it elapses — and both
  # backends take the same field, so it is set once here and passed to whichever opens.
  silence_duration_ms: LiveCeci.env_int("SILENCE_DURATION_MS", 400, 0..10_000),
  # Mic batch size, in 16 kHz samples, sent to the browser over /config.json. Also the
  # tail cost of an utterance: the last partial batch waits here before it is sent.
  # Smaller is not automatically faster — measured, 160 samples (10 ms) made latency
  # roughly 15x WORSE by head-of-line blocking on 375 frames/sec. Move it with
  # priv/spike/latency_bench.exs open.
  frame_samples: LiveCeci.env_int("FRAME_SAMPLES", 1600, 160..16_000)
