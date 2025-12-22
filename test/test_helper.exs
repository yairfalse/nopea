# Integration tests require the Rust binary to be built
# Run with: mix test --include integration

rust_binary_path =
  Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])

rust_binary_available? = File.exists?(rust_binary_path)
wants_integration? = Enum.any?(System.argv(), &(&1 =~ "integration"))

cond do
  # Someone wants to run integration tests but binary is missing
  wants_integration? and not rust_binary_available? ->
    IO.puts("""
    \n⚠️  Cannot run integration tests: Rust binary not found
       Path: #{rust_binary_path}

       Build with: cd nopea-git && cargo build --release

       Running non-integration tests only...
    """)

    # Force exclude integration tests even with --include flag
    ExUnit.start(exclude: [:integration])

  # Normal case: exclude integration by default
  true ->
    ExUnit.start(exclude: [:integration])
end
