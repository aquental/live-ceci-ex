[
  import_deps: [:plug],
  # priv/** included deliberately: the spikes there are real Elixir, and leaving them out
  # meant `mix format --check-formatted` in CI never looked at them. A gate with a
  # directory-sized hole in it reads as coverage it does not have.
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "priv/**/*.exs"]
]
