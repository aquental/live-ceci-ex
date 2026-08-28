import Config

config :live_dj,
  model: "gemini-3.1-flash-live-preview",
  voice: "Aoede",
  port: 8000,
  socket_handler: LiveDJ.Socket

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: []

import_config "#{config_env()}.exs"
