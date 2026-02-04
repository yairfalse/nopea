# Integration tests require the Rust binary to be built
# Run with: mix test --include integration

# Define Mox mocks
Mox.defmock(Nopea.K8sMock, for: Nopea.K8s.Behaviour)
Mox.defmock(Nopea.GitMock, for: Nopea.Git.Behaviour)

rust_binary_path =
  Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])

rust_binary_available? = File.exists?(rust_binary_path)
wants_integration? = Enum.any?(System.argv(), &(&1 =~ "integration"))

# Warn if integration tests requested but binary missing
if wants_integration? and not rust_binary_available? do
  IO.puts("""
  \n⚠️  Cannot run integration tests: Rust binary not found
     Path: #{rust_binary_path}

     Build with: cd nopea-git && cargo build --release

     Running non-integration tests only...
  """)
end

ExUnit.start(exclude: [:integration, :cluster])
