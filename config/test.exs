import Config

# Test configuration
# Disable all services for manual control in tests
config :nopea,
  enable_controller: false,
  enable_git: false,
  enable_cache: false,
  enable_supervisor: false

config :logger, level: :warning
