defmodule Nopea.Application do
  @moduledoc """
  NOPEA OTP Application.

  Supervision tree:
  - Nopea.ULID (monotonic ID generator)
  - Nopea.Events.Emitter (CDEvents HTTP emitter, optional)
  - Nopea.Cache (ETS storage)
  - Nopea.Registry (process name registry) OR Nopea.DistributedRegistry (cluster mode)
  - Nopea.Git (Rust Port GenServer)
  - Nopea.Supervisor (DynamicSupervisor for Workers) OR Nopea.DistributedSupervisor (cluster mode)
  - Nopea.Cluster (libcluster topology, cluster mode only)
  - Nopea.LeaderElection (Lease-based leader election, optional, non-cluster mode)
  - Nopea.Controller (CRD watcher, optional, starts in standby if leader election enabled)
  - Nopea.Webhook.Router (HTTP server for webhooks and health probes, always enabled)

  ## Configuration

  Services can be disabled via application config:

  - `enable_cache` - Enables Cache GenServer (default: true)
  - `enable_git` - Enables Git GenServer (default: true)
  - `enable_supervisor` - Enables Supervisor and Registry (default: true)
  - `enable_controller` - Enables Controller (default: true)
  - `enable_leader_election` - Enables leader election for HA (default: false)
  - `cluster_enabled` - Enables BEAM clustering with Horde (default: false)
  - `cdevents_endpoint` - CDEvents HTTP endpoint URL (nil to disable)

  ## Clustering Mode

  When `cluster_enabled` is true, NOPEA uses BEAM-native distribution:
  - Horde.Registry for cluster-wide unique process registration
  - Horde.DynamicSupervisor for distributed supervision with failover
  - libcluster for automatic node discovery in Kubernetes

  In cluster mode, leader election is NOT used - all nodes are equal and
  can own workers. Horde automatically distributes workers across nodes.

  ## Leader Election (Non-Cluster Mode)

  When `enable_leader_election` is true and `cluster_enabled` is false,
  multiple NOPEA replicas can run for high availability. Only the leader
  actively watches CRDs and manages workers - other replicas wait in standby.

  ## Service Dependencies

  The following dependencies exist between services:

  - `Nopea.Supervisor` requires `Nopea.Registry` (automatically started together)
  - `Nopea.DistributedSupervisor` requires `Nopea.DistributedRegistry` (cluster mode)
  - `Nopea.Worker` requires `Nopea.Git` to perform sync operations
  - `Nopea.Worker` optionally uses `Nopea.Cache` for sync state storage
  - `Nopea.Controller` waits for `Nopea.LeaderElection` when leader election enabled

  Note: In tests, `enable_*` flags are set to false and services are started
  manually via `start_supervised!/1` for isolation. When doing this, ensure
  `Application.put_env/3` is called to keep config in sync with running services.
  """

  use Application

  @impl true
  def start(_type, _args) do
    cluster_enabled = Application.get_env(:nopea, :cluster_enabled, false)
    leader_election_enabled = Application.get_env(:nopea, :enable_leader_election, false)

    # In cluster mode, leader election is not used - all nodes are equal
    effective_leader_election = leader_election_enabled and not cluster_enabled

    children =
      [Nopea.ULID]
      |> add_metrics_child()
      |> add_cdevents_child()
      |> add_cache_child()
      |> add_cluster_child(cluster_enabled)
      |> add_registry_child(cluster_enabled)
      |> add_git_child()
      |> add_supervisor_child(cluster_enabled)
      |> add_leader_election_child(effective_leader_election)
      |> add_controller_child(effective_leader_election)
      |> add_router_child()

    opts = [strategy: :one_for_one, name: Nopea.AppSupervisor]
    Supervisor.start_link(children, opts)
  end

  defp add_metrics_child(children) do
    if Application.get_env(:nopea, :enable_metrics, true) do
      children ++
        [
          {TelemetryMetricsPrometheus.Core,
           metrics: Nopea.Metrics.metrics(), name: :nopea_metrics}
        ]
    else
      children
    end
  end

  defp add_cdevents_child(children) do
    case Application.get_env(:nopea, :cdevents_endpoint) do
      nil -> children
      endpoint -> children ++ [{Nopea.Events.Emitter, endpoint: endpoint}]
    end
  end

  defp add_cache_child(children) do
    if Application.get_env(:nopea, :enable_cache, true),
      do: children ++ [Nopea.Cache],
      else: children
  end

  # Start libcluster for node discovery in cluster mode
  defp add_cluster_child(children, false), do: children

  defp add_cluster_child(children, true) do
    if Nopea.Cluster.enabled?() do
      children ++ [Nopea.Cluster.child_spec([])]
    else
      children
    end
  end

  # Start either local Registry or distributed Horde.Registry
  defp add_registry_child(children, cluster_enabled) do
    if Application.get_env(:nopea, :enable_supervisor, true) do
      if cluster_enabled do
        children ++ [Nopea.DistributedRegistry]
      else
        children ++ [{Registry, keys: :unique, name: Nopea.Registry}]
      end
    else
      children
    end
  end

  defp add_git_child(children) do
    if Application.get_env(:nopea, :enable_git, true), do: children ++ [Nopea.Git], else: children
  end

  # Start either local DynamicSupervisor or distributed Horde.DynamicSupervisor
  defp add_supervisor_child(children, cluster_enabled) do
    if Application.get_env(:nopea, :enable_supervisor, true) do
      if cluster_enabled do
        children ++ [Nopea.DistributedSupervisor]
      else
        children ++ [Nopea.Supervisor]
      end
    else
      children
    end
  end

  defp add_leader_election_child(children, false), do: children

  defp add_leader_election_child(children, true) do
    config = [
      lease_name: Application.get_env(:nopea, :leader_lease_name, "nopea-leader-election"),
      lease_namespace: System.get_env("POD_NAMESPACE", "nopea-system"),
      holder_identity: System.get_env("POD_NAME", node_identity()),
      lease_duration: Application.get_env(:nopea, :leader_lease_duration, 15),
      renew_deadline: Application.get_env(:nopea, :leader_renew_deadline, 10),
      retry_period: Application.get_env(:nopea, :leader_retry_period, 2)
    ]

    children ++ [{Nopea.LeaderElection, config}]
  end

  defp add_controller_child(children, leader_election_enabled) do
    if Application.get_env(:nopea, :enable_controller, true) do
      namespace = Application.get_env(:nopea, :watch_namespace, "default")
      children ++ [{Nopea.Controller, namespace: namespace, standby: leader_election_enabled}]
    else
      children
    end
  end

  defp add_router_child(children) do
    if Application.get_env(:nopea, :enable_router, true),
      do: children ++ [Nopea.Webhook.Router],
      else: children
  end

  # Generate unique node identity for leader election when POD_NAME not set
  defp node_identity do
    "nopea-#{:erlang.phash2(node())}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
