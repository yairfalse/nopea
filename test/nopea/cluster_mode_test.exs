defmodule Nopea.ClusterModeTest do
  @moduledoc """
  Tests for cluster mode integration.

  Verifies that when cluster_enabled is true:
  - DistributedRegistry is used for process registration
  - DistributedSupervisor is used for worker management
  - Worker.whereis() correctly queries the distributed registry
  """

  use ExUnit.Case, async: false

  alias Nopea.{DistributedRegistry, DistributedSupervisor, Supervisor, Worker}

  @moduletag :cluster

  # Start distributed services once for all tests
  setup_all do
    case DistributedRegistry.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case DistributedSupervisor.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "cluster mode registry" do
    setup do
      # Enable cluster mode
      Application.put_env(:nopea, :cluster_enabled, true)

      on_exit(fn ->
        Application.put_env(:nopea, :cluster_enabled, false)
      end)

      :ok
    end

    test "Worker.whereis uses DistributedRegistry in cluster mode" do
      key = "cluster-whereis-test-#{:rand.uniform(100_000)}"

      # Start an agent using the distributed registry directly
      {:ok, agent} = Agent.start_link(fn -> :test end, name: DistributedRegistry.via(key))

      # Worker.whereis should find it
      assert Worker.whereis(key) == agent

      Agent.stop(agent)
    end

    test "Worker.whereis returns nil for unknown key in cluster mode" do
      assert Worker.whereis("nonexistent-cluster-key-#{:rand.uniform(100_000)}") == nil
    end
  end

  describe "cluster mode supervisor" do
    setup do
      # Enable cluster mode
      Application.put_env(:nopea, :cluster_enabled, true)

      on_exit(fn ->
        Application.put_env(:nopea, :cluster_enabled, false)
      end)

      :ok
    end

    test "Supervisor.list_workers uses DistributedRegistry in cluster mode" do
      key = "cluster-list-test-#{:rand.uniform(100_000)}"

      # Register a process
      {:ok, agent} = Agent.start_link(fn -> :test end, name: DistributedRegistry.via(key))

      # list_workers should include it
      workers = Supervisor.list_workers()
      assert Enum.any?(workers, fn {k, _pid} -> k == key end)

      Agent.stop(agent)
    end

    test "Supervisor.get_worker uses Worker.whereis which uses DistributedRegistry" do
      key = "cluster-get-worker-#{:rand.uniform(100_000)}"

      {:ok, agent} = Agent.start_link(fn -> :test end, name: DistributedRegistry.via(key))

      assert {:ok, ^agent} = Supervisor.get_worker(key)

      Agent.stop(agent)
    end

    test "Supervisor.get_worker returns error for unknown key in cluster mode" do
      assert {:error, :not_found} =
               Supervisor.get_worker("nonexistent-cluster-worker-#{:rand.uniform(100_000)}")
    end
  end

  describe "non-cluster mode (default)" do
    setup do
      # Ensure cluster mode is disabled
      Application.put_env(:nopea, :cluster_enabled, false)

      # Start local registry
      case Registry.start_link(keys: :unique, name: Nopea.Registry) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      :ok
    end

    test "Worker.whereis uses local Registry when cluster disabled" do
      key = "local-whereis-test-#{:rand.uniform(100_000)}"

      # Start an agent using local registry
      {:ok, agent} =
        Agent.start_link(fn -> :test end, name: {:via, Registry, {Nopea.Registry, key}})

      # Worker.whereis should find it
      assert Worker.whereis(key) == agent

      Agent.stop(agent)
    end

    test "Supervisor.list_workers uses local Registry when cluster disabled" do
      key = "local-list-test-#{:rand.uniform(100_000)}"

      # Register via local registry
      {:ok, agent} =
        Agent.start_link(fn -> :test end, name: {:via, Registry, {Nopea.Registry, key}})

      workers = Supervisor.list_workers()
      assert Enum.any?(workers, fn {k, _pid} -> k == key end)

      Agent.stop(agent)
    end
  end
end
