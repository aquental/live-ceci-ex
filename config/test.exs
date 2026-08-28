import Config

config :logger, level: :warning

# Tests never reach the network; the key just has to exist so config validation passes.
config :gemini_ex, api_key: "test-key"

# 0 asks the OS for a free port. The test VM still boots the full app — Bandit
# included — so a fixed port makes `mix test` fail with :eaddrinuse whenever the
# dev server is already running, a failure that has nothing to do with the code.
config :live_dj, port: 0
