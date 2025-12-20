defmodule Nopea.SupervisorTest do
  use ExUnit.Case, async: false

  alias Nopea.Supervisor, as: NopSupervisor

  # Supervisor tests require Git (Workers call Git on startup)
  @moduletag :integration

  setup do
    # Check if Rust binary exists
    dev_path = Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])

    if File.exists?(dev_path) do
      start_supervised!(Nopea.Cache)
      start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
      start_supervised!(Nopea.Git)
      start_supervised!(Nopea.Supervisor)
      :ok
    else
      IO.puts("Skipping: Rust binary not built")
      :ok
    end
  end

  defp rust_binary_exists? do
    dev_path = Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])
    File.exists?(dev_path)
  end

  describe "start_worker/1" do
    @tag timeout: 30_000
    test "starts a worker for a repo config" do
      unless rust_binary_exists?(), do: flunk("Rust binary not built")

      config = test_config("start-test")

      assert {:ok, pid} = NopSupervisor.start_worker(config)
      assert Process.alive?(pid)

      # Cleanup
      NopSupervisor.stop_worker(config.name)
    end

    @tag timeout: 30_000
    test "returns error for duplicate repo name" do
      unless rust_binary_exists?(), do: flunk("Rust binary not built")

      config = test_config("dup-test")

      {:ok, _pid} = NopSupervisor.start_worker(config)
      assert {:error, {:already_started, _}} = NopSupervisor.start_worker(config)

      # Cleanup
      NopSupervisor.stop_worker(config.name)
    end
  end

  describe "stop_worker/1" do
    @tag timeout: 30_000
    test "stops a running worker" do
      unless rust_binary_exists?(), do: flunk("Rust binary not built")

      config = test_config("stop-test")

      {:ok, pid} = NopSupervisor.start_worker(config)
      assert Process.alive?(pid)

      :ok = NopSupervisor.stop_worker(config.name)
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    @tag timeout: 30_000
    test "returns error for unknown worker" do
      unless rust_binary_exists?(), do: flunk("Rust binary not built")

      assert {:error, :not_found} = NopSupervisor.stop_worker("unknown-repo")
    end
  end

  describe "list_workers/0" do
    @tag timeout: 30_000
    test "returns list of active workers" do
      unless rust_binary_exists?(), do: flunk("Rust binary not built")

      config1 = test_config("list-1")
      config2 = test_config("list-2")

      {:ok, _} = NopSupervisor.start_worker(config1)
      {:ok, _} = NopSupervisor.start_worker(config2)

      workers = NopSupervisor.list_workers()
      assert Enum.any?(workers, fn {name, _pid} -> name == config1.name end)
      assert Enum.any?(workers, fn {name, _pid} -> name == config2.name end)

      # Cleanup
      NopSupervisor.stop_worker(config1.name)
      NopSupervisor.stop_worker(config2.name)
    end
  end

  describe "get_worker/1" do
    @tag timeout: 30_000
    test "returns pid for known worker" do
      unless rust_binary_exists?(), do: flunk("Rust binary not built")

      config = test_config("get-test")

      {:ok, pid} = NopSupervisor.start_worker(config)
      assert {:ok, ^pid} = NopSupervisor.get_worker(config.name)

      # Cleanup
      NopSupervisor.stop_worker(config.name)
    end

    @tag timeout: 30_000
    test "returns error for unknown worker" do
      unless rust_binary_exists?(), do: flunk("Rust binary not built")

      assert {:error, :not_found} = NopSupervisor.get_worker("unknown")
    end
  end

  # Use a real public repo for tests
  defp test_config(prefix) do
    %{
      name: "#{prefix}-#{:rand.uniform(10000)}",
      url: "https://github.com/octocat/Hello-World.git",
      branch: "master",
      path: nil,
      interval: 300_000,
      target_namespace: nil
    }
  end
end
