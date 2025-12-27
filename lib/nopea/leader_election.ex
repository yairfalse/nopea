defmodule Nopea.LeaderElection do
  @moduledoc """
  Kubernetes Lease-based leader election for HA deployments.

  Uses the `coordination.k8s.io/v1` Lease API to elect a single leader
  among multiple NOPEA replicas. Only the leader runs the Controller
  (CRD watcher) - other pods wait in standby.

  ## How It Works

  1. On startup, attempts to create or acquire a Lease resource
  2. If successful, becomes leader and notifies Controller
  3. Renews the lease at half the lease duration interval
  4. If renewal fails or lease is taken, loses leadership

  ## Configuration

  - `lease_name` - Name of the Lease resource (default: "nopea-leader-election")
  - `lease_namespace` - Namespace for the Lease (default: POD_NAMESPACE)
  - `holder_identity` - Unique identity for this pod (default: POD_NAME)
  - `lease_duration` - Lease duration in seconds (default: 15)
  - `renew_deadline` - Max time to wait for renewal (default: 10)
  - `retry_period` - Time between acquisition attempts (default: 2)

  ## Example

      # In application.ex
      children = [
        {Nopea.LeaderElection, [
          lease_name: "nopea-leader-election",
          lease_namespace: "nopea-system",
          holder_identity: System.get_env("POD_NAME")
        ]}
      ]
  """

  use GenServer
  require Logger

  alias Nopea.Metrics

  @lease_api_version "coordination.k8s.io/v1"

  defstruct [
    :lease_name,
    :lease_namespace,
    :holder_identity,
    :lease_duration_seconds,
    :renew_deadline_seconds,
    :retry_period_seconds,
    :renew_timer,
    :k8s_module,
    is_leader: false
  ]

  @type t :: %__MODULE__{
          lease_name: String.t(),
          lease_namespace: String.t(),
          holder_identity: String.t(),
          lease_duration_seconds: pos_integer(),
          renew_deadline_seconds: pos_integer(),
          retry_period_seconds: pos_integer(),
          renew_timer: reference() | nil,
          k8s_module: module(),
          is_leader: boolean()
        }

  # ── Client API ────────────────────────────────────────────────────────────────

  @doc """
  Starts the leader election GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns whether this instance is currently the leader.
  """
  @spec leader?() :: boolean()
  def leader? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :leader?)
    end
  end

  # ── Server Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    with {:ok, lease_namespace} <- fetch_required(opts, :lease_namespace),
         {:ok, holder_identity} <- fetch_required(opts, :holder_identity) do
      state = %__MODULE__{
        lease_name: Keyword.get(opts, :lease_name, "nopea-leader-election"),
        lease_namespace: lease_namespace,
        holder_identity: holder_identity,
        lease_duration_seconds: Keyword.get(opts, :lease_duration, 15),
        renew_deadline_seconds: Keyword.get(opts, :renew_deadline, 10),
        retry_period_seconds: Keyword.get(opts, :retry_period, 2),
        k8s_module: Keyword.get(opts, :k8s_module, Nopea.K8s),
        is_leader: false
      }

      Logger.info(
        "LeaderElection starting: lease=#{state.lease_namespace}/#{state.lease_name}, " <>
          "identity=#{state.holder_identity}"
      )

      # Start election loop
      send(self(), :try_acquire)

      {:ok, state}
    else
      {:error, {:missing_option, key}} ->
        {:stop, {:missing_required_option, key}}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  @impl true
  def handle_call(:leader?, _from, state) do
    {:reply, state.is_leader, state}
  end

  @impl true
  def handle_info(:try_acquire, state) do
    case try_acquire_or_renew(state) do
      {:ok, :acquired} ->
        Logger.info("Acquired leadership for #{state.lease_name}")
        notify_controller(true)
        timer = schedule_renew(state)
        {:noreply, %{state | is_leader: true, renew_timer: timer}}

      {:ok, :renewed} ->
        # We already held the lease (e.g., pod restart) - become leader
        unless state.is_leader do
          Logger.info("Reclaimed leadership for #{state.lease_name}")
          notify_controller(true)
        end

        timer = schedule_renew(state)
        {:noreply, %{state | is_leader: true, renew_timer: timer}}

      {:ok, :not_leader} ->
        if state.is_leader do
          Logger.warning("Lost leadership - another pod acquired lease")
          notify_controller(false)
        end

        cancel_timer(state.renew_timer)
        schedule_retry(state)
        {:noreply, %{state | is_leader: false, renew_timer: nil}}

      {:error, reason} ->
        Logger.warning("Leader election error: #{inspect(reason)}, retrying...")
        schedule_retry(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:renew, state) do
    case try_acquire_or_renew(state) do
      {:ok, :renewed} ->
        timer = schedule_renew(state)
        {:noreply, %{state | renew_timer: timer}}

      {:ok, :lost} ->
        Logger.warning("Lost leadership - failed to renew lease")
        notify_controller(false)
        cancel_timer(state.renew_timer)
        schedule_retry(state)
        {:noreply, %{state | is_leader: false, renew_timer: nil}}

      {:ok, :not_leader} ->
        Logger.warning("Lost leadership - lease taken by another pod")
        notify_controller(false)
        cancel_timer(state.renew_timer)
        schedule_retry(state)
        {:noreply, %{state | is_leader: false, renew_timer: nil}}

      {:error, reason} ->
        Logger.error("Failed to renew lease: #{inspect(reason)}")
        # On error, assume we lost leadership for safety
        notify_controller(false)
        cancel_timer(state.renew_timer)
        schedule_retry(state)
        {:noreply, %{state | is_leader: false, renew_timer: nil}}
    end
  end

  # ── Private Functions ─────────────────────────────────────────────────────────

  defp try_acquire_or_renew(state) do
    with {:ok, conn} <- state.k8s_module.conn() do
      case get_lease(conn, state) do
        {:ok, lease} ->
          handle_existing_lease(conn, state, lease)

        {:error, :not_found} ->
          create_lease(conn, state)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_lease(conn, state) do
    op =
      K8s.Client.get(
        @lease_api_version,
        "Lease",
        namespace: state.lease_namespace,
        name: state.lease_name
      )

    case K8s.Client.run(conn, op) do
      {:ok, lease} -> {:ok, lease}
      {:error, %K8s.Client.APIError{reason: "NotFound"}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_lease(conn, state) do
    now = DateTime.utc_now()

    lease = %{
      "apiVersion" => @lease_api_version,
      "kind" => "Lease",
      "metadata" => %{
        "name" => state.lease_name,
        "namespace" => state.lease_namespace
      },
      "spec" => %{
        "holderIdentity" => state.holder_identity,
        "leaseDurationSeconds" => state.lease_duration_seconds,
        "acquireTime" => format_micro_time(now),
        "renewTime" => format_micro_time(now),
        "leaseTransitions" => 0
      }
    }

    op = K8s.Client.create(lease)

    case K8s.Client.run(conn, op) do
      {:ok, _} -> {:ok, :acquired}
      {:error, %K8s.Client.APIError{reason: "AlreadyExists"}} -> {:ok, :not_leader}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_existing_lease(conn, state, lease) do
    holder = get_in(lease, ["spec", "holderIdentity"])
    renew_time = get_in(lease, ["spec", "renewTime"])
    duration = get_in(lease, ["spec", "leaseDurationSeconds"]) || state.lease_duration_seconds

    cond do
      holder == state.holder_identity ->
        # We are the current holder, renew
        renew_lease(conn, state, lease)

      lease_expired?(renew_time, duration) ->
        # Lease expired, try to take over
        Logger.info("Lease expired (holder=#{holder}), attempting takeover")
        take_over_lease(conn, state, lease)

      true ->
        # Someone else is the valid leader
        {:ok, :not_leader}
    end
  end

  defp lease_expired?(nil, _duration), do: true

  defp lease_expired?(renew_time, duration) do
    case parse_micro_time(renew_time) do
      {:ok, dt} ->
        now = DateTime.utc_now()
        DateTime.diff(now, dt, :second) > duration

      {:error, _} ->
        # If we can't parse, assume expired
        true
    end
  end

  defp renew_lease(conn, _state, lease) do
    now = DateTime.utc_now()

    updated =
      lease
      |> put_in(["spec", "renewTime"], format_micro_time(now))

    op = K8s.Client.update(updated)

    case K8s.Client.run(conn, op) do
      {:ok, _} -> {:ok, :renewed}
      {:error, %K8s.Client.APIError{reason: "Conflict"}} -> {:ok, :lost}
      {:error, reason} -> {:error, reason}
    end
  end

  defp take_over_lease(conn, state, lease) do
    now = DateTime.utc_now()
    transitions = (get_in(lease, ["spec", "leaseTransitions"]) || 0) + 1

    updated =
      lease
      |> put_in(["spec", "holderIdentity"], state.holder_identity)
      |> put_in(["spec", "acquireTime"], format_micro_time(now))
      |> put_in(["spec", "renewTime"], format_micro_time(now))
      |> put_in(["spec", "leaseTransitions"], transitions)

    op = K8s.Client.update(updated)

    case K8s.Client.run(conn, op) do
      {:ok, _} -> {:ok, :acquired}
      {:error, %K8s.Client.APIError{reason: "Conflict"}} -> {:ok, :not_leader}
      {:error, reason} -> {:error, reason}
    end
  end

  defp notify_controller(is_leader) do
    # Emit leader change metrics
    pod_name = System.get_env("POD_NAME", node() |> to_string())
    Metrics.emit_leader_change(%{pod: pod_name, is_leader: is_leader})

    case Process.whereis(Nopea.Controller) do
      nil -> :ok
      pid -> send(pid, {:leader, is_leader})
    end
  end

  defp schedule_renew(state) do
    # Renew at half the lease duration for safety margin
    interval = div(state.lease_duration_seconds * 1000, 2)
    Process.send_after(self(), :renew, interval)
  end

  defp schedule_retry(state) do
    Process.send_after(self(), :try_acquire, state.retry_period_seconds * 1000)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  # K8s uses MicroTime format (RFC3339 with microseconds)
  defp format_micro_time(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp parse_micro_time(time_string) when is_binary(time_string) do
    case DateTime.from_iso8601(time_string) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_micro_time(_), do: {:error, :invalid_format}
end
