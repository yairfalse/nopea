defmodule Alumiini.WorkerTest do
  use ExUnit.Case, async: false

  alias Alumiini.Worker

  # These tests require Git GenServer (Rust binary)
  @moduletag :integration

  describe "start_link/1" do
    test "starts a worker with config" do
      config = %{
        name: "worker-test-#{:rand.uniform(1000)}",
        url: "https://github.com/test/repo.git",
        branch: "main",
        path: "deploy/",
        interval: 300_000
      }

      assert {:ok, pid} = Worker.start_link(config)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "get_state/1" do
    test "returns current worker state" do
      config = %{
        name: "state-test-#{:rand.uniform(1000)}",
        url: "https://github.com/test/repo.git",
        branch: "main",
        path: "deploy/",
        interval: 300_000
      }

      {:ok, pid} = Worker.start_link(config)

      state = Worker.get_state(pid)
      assert state.config.name == config.name
      assert state.config.url == config.url
      # Status may be :initializing, :synced, or :failed depending on timing and git availability
      assert state.status in [:initializing, :synced, :failed]

      GenServer.stop(pid)
    end
  end

  describe "sync_now/1" do
    test "triggers immediate sync" do
      config = %{
        name: "sync-test-#{:rand.uniform(1000)}",
        url: "https://github.com/test/repo.git",
        branch: "main",
        path: "deploy/",
        interval: 300_000
      }

      {:ok, pid} = Worker.start_link(config)

      # Trigger sync (will fail because git repo doesn't exist, but should not crash)
      result = Worker.sync_now(pid)
      assert match?(:ok, result) or match?({:error, _}, result)

      GenServer.stop(pid)
    end
  end

  describe "name registration" do
    test "can find worker by repo name" do
      config = %{
        name: "named-test-#{:rand.uniform(1000)}",
        url: "https://github.com/test/repo.git",
        branch: "main",
        path: "deploy/",
        interval: 300_000
      }

      {:ok, pid} = Worker.start_link(config)

      # Can find by name via Registry
      found_pid = Worker.whereis(config.name)
      assert found_pid == pid

      GenServer.stop(pid)
    end
  end
end
