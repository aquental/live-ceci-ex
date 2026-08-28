import Config

config :logger, level: :warning

# Tests never reach the network; the key just has to exist so config validation passes.
config :gemini_ex, api_key: "test-key"
