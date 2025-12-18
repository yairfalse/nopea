defmodule Nopea.GitTest do
  use ExUnit.Case, async: false

  alias Nopea.Git

  setup do
    # Start Git GenServer for integration tests if binary exists
    if rust_binary_exists?() do
      start_supervised!(Nopea.Git)
    end

    :ok
  end

  describe "decode_content/1" do
    test "decodes valid base64 content" do
      content = "hello world"
      encoded = Base.encode64(content)

      assert {:ok, ^content} = Git.decode_content(encoded)
    end

    test "returns error for invalid base64" do
      assert {:error, :invalid_base64} = Git.decode_content("not-valid-base64!!!")
    end

    test "decodes empty string" do
      encoded = Base.encode64("")
      assert {:ok, ""} = Git.decode_content(encoded)
    end

    test "decodes binary content" do
      binary = <<0, 1, 2, 255, 254, 253>>
      encoded = Base.encode64(binary)

      assert {:ok, ^binary} = Git.decode_content(encoded)
    end
  end

  # Integration tests require the Rust binary to be built
  # These are tagged and can be run with: mix test --only integration
  @moduletag :integration

  describe "sync/4 integration" do
    @tag :integration
    @tag timeout: 60_000
    test "clones a public repository" do
      # Skip if Rust binary not built
      unless rust_binary_exists?() do
        IO.puts("Skipping: Rust binary not built")
        :ok
      else
        path = "/tmp/nopea-test-#{:rand.uniform(100_000)}"

        try do
          result =
            Git.sync(
              "https://github.com/octocat/Hello-World.git",
              "master",
              path
            )

          assert {:ok, commit_sha} = result
          assert is_binary(commit_sha)
          # SHA-1 hash
          assert String.length(commit_sha) == 40
          assert File.exists?(Path.join(path, ".git"))
        after
          File.rm_rf!(path)
        end
      end
    end
  end

  describe "files/2 integration" do
    @tag :integration
    test "lists YAML files in directory" do
      unless rust_binary_exists?() do
        IO.puts("Skipping: Rust binary not built")
        :ok
      else
        path = "/tmp/nopea-test-files-#{:rand.uniform(100_000)}"

        try do
          File.mkdir_p!(path)
          File.write!(Path.join(path, "deploy.yaml"), "apiVersion: v1")
          File.write!(Path.join(path, "config.yml"), "data: {}")
          File.write!(Path.join(path, "readme.md"), "# README")
          File.write!(Path.join(path, ".hidden.yaml"), "secret: true")

          result = Git.files(path, nil)

          assert {:ok, files} = result
          assert "deploy.yaml" in files
          assert "config.yml" in files
          refute "readme.md" in files
          refute ".hidden.yaml" in files
        after
          File.rm_rf!(path)
        end
      end
    end
  end

  describe "read/2 integration" do
    @tag :integration
    test "reads file content as base64" do
      unless rust_binary_exists?() do
        IO.puts("Skipping: Rust binary not built")
        :ok
      else
        path = "/tmp/nopea-test-read-#{:rand.uniform(100_000)}"

        try do
          content = "apiVersion: v1\nkind: ConfigMap"
          File.mkdir_p!(path)
          File.write!(Path.join(path, "test.yaml"), content)

          result = Git.read(path, "test.yaml")

          assert {:ok, base64_content} = result
          assert {:ok, ^content} = Git.decode_content(base64_content)
        after
          File.rm_rf!(path)
        end
      end
    end
  end

  describe "head/1 integration" do
    @tag :integration
    test "returns commit info from git repository" do
      unless rust_binary_exists?() do
        IO.puts("Skipping: Rust binary not built")
        :ok
      else
        path = "/tmp/nopea-test-head-#{:rand.uniform(100_000)}"

        try do
          # Initialize git repo
          File.mkdir_p!(path)
          System.cmd("git", ["init"], cd: path)
          System.cmd("git", ["config", "user.name", "Test User"], cd: path)
          System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)

          # Create a commit
          File.write!(Path.join(path, "test.txt"), "hello")
          System.cmd("git", ["add", "."], cd: path)
          System.cmd("git", ["commit", "-m", "Initial commit"], cd: path)

          # Test head
          result = Git.head(path)

          assert {:ok, info} = result
          assert is_binary(info.sha)
          assert String.length(info.sha) == 40
          assert info.author == "Test User"
          assert info.email == "test@example.com"
          assert info.message =~ "Initial commit"
          assert is_integer(info.timestamp)
          assert info.timestamp > 0
        after
          File.rm_rf!(path)
        end
      end
    end
  end

  defp rust_binary_exists? do
    dev_path = Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])
    File.exists?(dev_path)
  end
end
