import Config

config :live_ceci,
  model: "gemini-3.1-flash-live-preview",
  voice: "Aoede",
  port: 8000

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: []

import_config "#{config_env()}.exs"
