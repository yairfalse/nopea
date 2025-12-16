import Config

# Test configuration
config :alumiini,
  # Disable controller in tests (requires K8s cluster)
  enable_controller: false,
  # Disable Git GenServer in tests (requires Rust binary)
  enable_git: false

config :logger, level: :warning
