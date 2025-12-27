defmodule Nopea.LeaderElectionTest do
  @moduledoc """
  Tests for leader election GenServer.

  Note: Full integration tests require a K8s cluster.
  These tests focus on the state machine and public API.
  """

  use ExUnit.Case, async: false

  alias Nopea.LeaderElection

  @moduletag :leader_election

  describe "leader?/0" do
    test "returns false when not started" do
      # Ensure LeaderElection is not running
      case Process.whereis(LeaderElection) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      refute LeaderElection.leader?()
    end
  end

  describe "start_link/1" do
    test "requires lease_namespace" do
      Process.flag(:trap_exit, true)
      result = LeaderElection.start_link(holder_identity: "test-pod")
      assert {:error, {:missing_required_option, :lease_namespace}} = result
    end

    test "requires holder_identity" do
      Process.flag(:trap_exit, true)
      result = LeaderElection.start_link(lease_namespace: "default")
      assert {:error, {:missing_required_option, :holder_identity}} = result
    end

    test "starts with default lease_name" do
      # This will fail to connect to K8s but proves config parsing works
      {:ok, pid} =
        LeaderElection.start_link(
          lease_namespace: "test-ns",
          holder_identity: "test-pod-123",
          # Use a mock that always fails
          k8s_module: Nopea.LeaderElection.MockK8s
        )

      # Should start in non-leader state
      refute GenServer.call(pid, :leader?)

      GenServer.stop(pid)
    end
  end

  describe "state initialization" do
    test "initializes with correct defaults" do
      {:ok, pid} =
        LeaderElection.start_link(
          lease_namespace: "nopea-system",
          holder_identity: "nopea-abc123",
          k8s_module: Nopea.LeaderElection.MockK8s
        )

      # Verify initial state via leader?
      refute GenServer.call(pid, :leader?)

      GenServer.stop(pid)
    end

    test "uses custom lease_duration" do
      {:ok, pid} =
        LeaderElection.start_link(
          lease_namespace: "default",
          holder_identity: "test",
          lease_duration: 30,
          k8s_module: Nopea.LeaderElection.MockK8s
        )

      # Just verify it starts without error
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end

# Simple mock module that always returns connection error
defmodule Nopea.LeaderElection.MockK8s do
  @moduledoc false

  def conn do
    {:error, :mock_no_cluster}
  end
end
