defmodule Nopea.Application do
  @moduledoc """
  NOPEA OTP Application.

  Supervision tree:
  - Nopea.ULID (monotonic ID generator)
  - Nopea.Events.Emitter (CDEvents HTTP emitter, optional)
  - Nopea.Cache (ETS storage)
  - Nopea.Registry (process name registry)
  - Nopea.Git (Rust Port GenServer)
  - Nopea.Supervisor (DynamicSupervisor for Workers)
  - Nopea.LeaderElection (Lease-based leader election, optional)
  - Nopea.Controller (CRD watcher, optional, starts in standby if leader election enabled)
  - Nopea.Webhook.Router (HTTP server for webhooks and health probes, always enabled)

  ## Configuration

  Services can be disabled via application config:

  - `enable_cache` - Enables Cache GenServer (default: true)
  - `enable_git` - Enables Git GenServer (default: true)
  - `enable_supervisor` - Enables Supervisor and Registry (default: true)
  - `enable_controller` - Enables Controller (default: true)
  - `enable_leader_election` - Enables leader election for HA (default: false)
  - `cdevents_endpoint` - CDEvents HTTP endpoint URL (nil to disable)

  ## Leader Election

  When `enable_leader_election` is true, multiple NOPEA replicas can run
  for high availability. Only the leader actively watches CRDs and manages
  workers - other replicas wait in standby.

  ## Service Dependencies

  The following dependencies exist between services:

  - `Nopea.Supervisor` requires `Nopea.Registry` (automatically started together)
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
    # ULID generator (monotonic, needed for events)
    children = [Nopea.ULID]

    # Prometheus metrics reporter
    children =
      if Application.get_env(:nopea, :enable_metrics, true) do
        children ++
          [
            {TelemetryMetricsPrometheus.Core,
             metrics: Nopea.Metrics.metrics(), name: :nopea_metrics}
          ]
      else
        children
      end

    # CDEvents emitter (optional, enabled when endpoint is configured)
    children =
      case Application.get_env(:nopea, :cdevents_endpoint) do
        nil ->
          children

        endpoint ->
          children ++ [{Nopea.Events.Emitter, endpoint: endpoint}]
      end

    # ETS cache for commits, resources, sync state
    children =
      if Application.get_env(:nopea, :enable_cache, true) do
        children ++ [Nopea.Cache]
      else
        children
      end

    # Registry for worker name lookup (always needed if supervisor is enabled)
    children =
      if Application.get_env(:nopea, :enable_supervisor, true) do
        children ++ [{Registry, keys: :unique, name: Nopea.Registry}]
      else
        children
      end

    # Git GenServer (Rust Port)
    children =
      if Application.get_env(:nopea, :enable_git, true) do
        children ++ [Nopea.Git]
      else
        children
      end

    # DynamicSupervisor for Worker processes
    children =
      if Application.get_env(:nopea, :enable_supervisor, true) do
        children ++ [Nopea.Supervisor]
      else
        children
      end

    # Leader election (optional, for HA deployments)
    leader_election_enabled = Application.get_env(:nopea, :enable_leader_election, false)

    children =
      if leader_election_enabled do
        config = [
          lease_name: Application.get_env(:nopea, :leader_lease_name, "nopea-leader-election"),
          lease_namespace: System.get_env("POD_NAMESPACE", "nopea-system"),
          holder_identity: System.get_env("POD_NAME", node_identity()),
          lease_duration: Application.get_env(:nopea, :leader_lease_duration, 15),
          renew_deadline: Application.get_env(:nopea, :leader_renew_deadline, 10),
          retry_period: Application.get_env(:nopea, :leader_retry_period, 2)
        ]

        children ++ [{Nopea.LeaderElection, config}]
      else
        children
      end

    # Controller (watches GitRepository CRDs)
    # Starts in standby mode when leader election is enabled
    children =
      if Application.get_env(:nopea, :enable_controller, true) do
        namespace = Application.get_env(:nopea, :watch_namespace, "default")
        children ++ [{Nopea.Controller, namespace: namespace, standby: leader_election_enabled}]
      else
        children
      end

    # Webhook HTTP server (for health/readiness probes and webhooks)
    children =
      if Application.get_env(:nopea, :enable_router, true) do
        children ++ [Nopea.Webhook.Router]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Nopea.AppSupervisor]
    Supervisor.start_link(children, opts)
  end

  # Generate unique node identity for leader election when POD_NAME not set
  defp node_identity do
    "nopea-#{:erlang.phash2(node())}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
