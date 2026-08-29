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

# MODEL picks the backend. Read here rather than baked in at compile time, so switching
# providers is an .env edit and a restart.
#
# This `case` used to carry each backend's default model and voice, and the comment
# defending that arrangement had to explain why a shared default was impossible: it
# "would have to belong to one of them, and then the other would silently inherit a model
# name that means nothing to it". That is a description of knowledge in the wrong file.
# The defaults live in the providers now — see `c:LiveCeci.Provider.defaults/0` — and all
# that is left here is the one thing this file is for, which is mapping a name in the
# environment to a module.
provider =
  case System.get_env("MODEL") |> to_string() |> String.upcase() do
    "GOOGLE" -> LiveCeci.Provider.Gemini
    _ -> LiveCeci.Provider.Grok
  end

defaults = provider.defaults()
model = System.get_env(defaults.model_env) || defaults.model
voice = System.get_env(defaults.voice_env) || defaults.voice

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
  frame_samples: LiveCeci.env_int("FRAME_SAMPLES", 1600, 160..16_000),
  # Who decides your turn ended. Measured on xAI, three interleaved reps against a fixed
  # utterance: 1818 ms median with server_vad, 985 ms with the browser's gate closing the
  # turn. Default is the fast one; TURN_DETECTION=server is the way back if false turns
  # start cutting people off mid-sentence, which is the risk this trades for the 833 ms.
  # Gemini ignores it — its own VAD already answers in 1220 ms.
  turn_detection: if(System.get_env("TURN_DETECTION") == "server", do: :server, else: :manual),
  # How many live sessions may exist at once, and how many from one address. Each one
  # holds an upstream session that is billed while it lives, and eight tabs is eight of
  # them. Bound to loopback the two numbers coincide; they stop coinciding the moment
  # BIND_IP opens.
  #
  # What actually limits these is NOT this machine. Measured: file descriptors, ports and
  # processes all cap at 1_048_576 here, and LiveCeci.Sessions costs microseconds per
  # connection at any setting worth using. The binding constraint is the provider's own
  # concurrency and rate limits, which are not documented and were not tested — raising
  # MAX_SESSIONS is a question for xAI or Google, not for this file.
  max_sessions: LiveCeci.env_int("MAX_SESSIONS", 8, 1..1_000),
  # How many upgrade tickets one address may hold at once. On loopback that is one
  # person; behind a NAT or a reverse proxy it is everyone, and then this — not
  # MAX_SESSIONS — is what caps concurrent users.
  # The global bound on outstanding tickets is DERIVED from this, at twice the value, so
  # the two cannot be raised out of step. See LiveCeci.Tickets.
  #
  # The range used to end at 100_000 and now ends at 2_000, which is a narrowing on
  # purpose. LiveCeci.Tickets.issue/1 does three passes over the table — the per-address
  # count, the sweep, and the eviction fold — and a performance audit measured what that
  # costs as the table grows: 73 µs a mint at the default 300 rows, 446 µs at 2_000,
  # 4.0 ms at 20_000 and 45 ms at 200_000. Past a couple of thousand the bound that exists
  # to prevent a denial of service becomes one, and the setting that gets you there is
  # exactly the NAT/proxy deployment the comment above tells you to raise it for.
  #
  # 2_000 per address means a 4_000-row table and under a millisecond a mint, which is
  # more concurrent connecting users than anything this app is going to see. Raising it
  # further needs per-address counters kept in the counters table, not a bigger number.
  max_tickets_per_address: LiveCeci.env_int("MAX_TICKETS_PER_ADDRESS", 150, 1..2_000),
  max_sessions_per_address: LiveCeci.env_int("MAX_SESSIONS_PER_ADDRESS", 4, 1..1_000),
  # How long one session may live and how much microphone it may send, regardless of
  # activity. Bandit's WebSocket `:timeout` is an IDLE timeout and an open microphone is
  # never idle, so before these existed nothing closed a forgotten tab — it held an
  # upstream session, billed, until the laptop slept. See LiveCeci.Limits.
  max_session_ms: LiveCeci.env_int("MAX_SESSION_SECONDS", 900, 30..86_400) * 1000,
  max_session_bytes: LiveCeci.env_int("MAX_SESSION_MB", 100, 1..10_000) * 1_000_000,
  # Addresses that are allowed to rewrite the client address via X-Forwarded-For, comma
  # separated. EMPTY BY DEFAULT, and while it is empty the header is ignored entirely —
  # anyone can send an X-Forwarded-For, so trusting it without knowing who is in front of
  # you hands every caller a supply of invented identities. Set this to the address of
  # your reverse proxy and to nothing else.
  trusted_proxies:
    System.get_env("TRUSTED_PROXIES")
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn address ->
      case :inet.parse_address(String.to_charlist(address)) do
        {:ok, parsed} ->
          [parsed]

        {:error, _} ->
          IO.warn("TRUSTED_PROXIES entry #{inspect(address)} is not an IP address; ignoring")
          []
      end
    end),
  # Extra origins allowed to open /ws, comma separated, as scheme://host[:port]. Compared
  # as a parsed {scheme, host, port} triple, so case and a default port written either way
  # both match. Loopback origins are always allowed and do not need listing — see
  # LiveCeci.Router. This is for the day BIND_IP opens up and a real page needs in.
  allowed_origins:
    System.get_env("ALLOWED_ORIGINS")
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
