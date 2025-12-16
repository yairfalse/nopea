# Exclude integration tests by default (require Rust binary)
# Run with: mix test --include integration
ExUnit.start(exclude: [:integration])
