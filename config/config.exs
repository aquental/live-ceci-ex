import Config

# Model and voice are not here: they are per-provider, and config/runtime.exs sets
# them alongside the provider that gives them meaning.
config :live_ceci, port: 8000

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: []

import_config "#{config_env()}.exs"
