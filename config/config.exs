import Config

# Model and voice are not here: they are per-provider, and config/runtime.exs sets
# them alongside the provider that gives them meaning.
# The default backend. It lives here rather than as a fallback inside
# LiveCeci.Provider.current/0 so the behaviour does not name one of its own
# implementations — config/runtime.exs overrides it from MODEL.
config :live_ceci, provider: LiveCeci.Provider.Grok, port: 8000

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: []

import_config "#{config_env()}.exs"
