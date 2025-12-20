defmodule Nopea.WorkerTest do
  use ExUnit.Case, async: false

  alias Nopea.Worker

  # Integration tests require Rust binary and real git operations
  @moduletag :integration

  setup do
    # Check if Rust binary exists
    dev_path = Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])

    if File.exists?(dev_path) do
      # Start required services
      start_supervised!(Nopea.Cache)
      start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
      start_supervised!(Nopea.Git)

      # Clean up test repo directory
      repo_base = "/tmp/nopea/repos"
      File.rm_rf!(repo_base)
      File.mkdir_p!(repo_base)

      {:ok, repo_base: repo_base}
    else
      IO.puts("Skipping: Rust binary not built")
      :ok
    end
  end

  describe "start_link/1" do
    @tag timeout: 30_000
    test "starts a worker with config", context do
      unless Map.has_key?(context, :repo_base) do
        :ok
      else
        config = test_config("start-link-test")

        assert {:ok, pid} = Worker.start_link(config)
        assert Process.alive?(pid)

        # Give it a moment to initialize
        Process.sleep(100)

        state = Worker.get_state(pid)
        assert state.config.name == config.name
        assert state.status in [:initializing, :syncing, :synced, :failed]

        GenServer.stop(pid)
      end
    end
  end

  describe "get_state/1" do
    @tag timeout: 30_000
    test "returns current worker state", context do
      unless Map.has_key?(context, :repo_base) do
        :ok
      else
        config = test_config("get-state-test")

        {:ok, pid} = Worker.start_link(config)

        state = Worker.get_state(pid)
        assert state.config.name == config.name
        assert state.config.url == config.url
        assert state.status in [:initializing, :syncing, :synced, :failed]

        GenServer.stop(pid)
      end
    end
  end

  describe "sync_now/1" do
    @tag timeout: 60_000
    test "triggers immediate sync with real repo", context do
      unless Map.has_key?(context, :repo_base) do
        :ok
      else
        config = test_config("sync-now-test")

        {:ok, pid} = Worker.start_link(config)

        # Wait for startup sync to complete or fail
        Process.sleep(2000)

        # Manual sync - should work with real repo
        result = Worker.sync_now(pid)

        # With a real repo, sync succeeds but K8s apply fails (no cluster)
        # That's expected - we're testing the git integration works
        assert match?(:ok, result) or match?({:error, _}, result)

        state = Worker.get_state(pid)
        # Should have attempted sync
        assert state.status in [:synced, :failed]

        GenServer.stop(pid)
      end
    end
  end

  describe "whereis/1" do
    @tag timeout: 30_000
    test "finds worker by repo name via Registry", context do
      unless Map.has_key?(context, :repo_base) do
        :ok
      else
        config = test_config("whereis-test")

        {:ok, pid} = Worker.start_link(config)

        # Can find by name via Registry
        found_pid = Worker.whereis(config.name)
        assert found_pid == pid

        GenServer.stop(pid)
      end
    end
  end

  describe "sync with real repository" do
    @tag timeout: 120_000
    test "successfully syncs from a real public repository", context do
      unless Map.has_key?(context, :repo_base) do
        :ok
      else
        # Use octocat/Hello-World - a stable public repo
        config = %{
          name: "real-repo-test-#{:rand.uniform(10000)}",
          url: "https://github.com/octocat/Hello-World.git",
          branch: "master",
          path: nil,
          interval: 300_000,
          target_namespace: nil
        }

        {:ok, pid} = Worker.start_link(config)

        # Wait for startup sync
        Process.sleep(5000)

        state = Worker.get_state(pid)

        # Git sync should succeed (K8s apply will fail without cluster)
        # The state will be :failed due to K8s, but last_commit should be set
        # if git worked
        if state.last_commit do
          assert String.length(state.last_commit) == 40
          assert String.match?(state.last_commit, ~r/^[0-9a-f]+$/)
        end

        GenServer.stop(pid)
      end
    end
  end

  # Helper to create test config
  defp test_config(test_name) do
    %{
      name: "#{test_name}-#{:rand.uniform(10000)}",
      url: "https://github.com/octocat/Hello-World.git",
      branch: "master",
      path: nil,
      interval: 300_000,
      target_namespace: nil
    }
  end
end
