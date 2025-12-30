defmodule Nopea.Controller do
  @moduledoc """
  Controller for watching GitRepository CRDs and managing Workers.

  Watches GitRepository resources and:
  - ADDED: Starts a new Worker
  - MODIFIED: Updates Worker if needed
  - DELETED: Stops the Worker

  ## Standby Mode

  When leader election is enabled, the controller starts in standby mode.
  It waits for `{:leader, true}` message from LeaderElection before
  starting to watch CRDs. On `{:leader, false}`, it stops all workers
  and returns to standby.
  """

  use GenServer
  require Logger

  alias Nopea.{K8s, Supervisor}

  @default_namespace "default"
  @reconnect_delay 5_000

  defstruct [
    :namespace,
    :watch_ref,
    :resource_version,
    repos: %{},
    standby: false
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current state of the controller.
  """
  @spec get_state() :: map()
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    standby = Keyword.get(opts, :standby, false)

    Logger.info("Controller starting, watching namespace: #{namespace}, standby: #{standby}")

    state = %__MODULE__{
      namespace: namespace,
      repos: %{},
      standby: standby
    }

    # Only start watching if not in standby mode
    unless standby do
      send(self(), :start_watch)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_info(:start_watch, state) do
    # Skip if in standby mode (prevents race condition with delayed messages)
    if state.standby do
      Logger.debug("Ignoring :start_watch - controller in standby mode")
      {:noreply, state}
    else
      do_start_watch(state)
    end
  end

  def handle_info(:reconnect, state) do
    Logger.info("Reconnecting watch...")
    send(self(), :start_watch)
    {:noreply, state}
  end

  def handle_info({:watch_event, event}, state) do
    new_state = handle_watch_event(event, state)
    {:noreply, new_state}
  end

  def handle_info({:watch_error, reason}, state) do
    Logger.warning("Watch error: #{inspect(reason)}, reconnecting...")
    schedule_reconnect()
    {:noreply, %{state | watch_ref: nil}}
  end

  def handle_info({:watch_done, _ref}, state) do
    Logger.info("Watch stream ended, reconnecting...")
    schedule_reconnect()
    {:noreply, %{state | watch_ref: nil}}
  end

  # Leadership messages from LeaderElection
  def handle_info({:leader, true}, state) do
    Logger.info("Became leader, starting CRD watch")
    send(self(), :start_watch)
    {:noreply, %{state | standby: false}}
  end

  def handle_info({:leader, false}, state) do
    Logger.info("Lost leadership, stopping all workers and entering standby")

    # Stop all workers
    Enum.each(state.repos, fn {name, _version} ->
      case Supervisor.stop_worker(name) do
        :ok -> Logger.debug("Stopped worker: #{name}")
        {:error, reason} -> Logger.warning("Failed to stop worker #{name}: #{inspect(reason)}")
      end
    end)

    # Clear state and enter standby
    {:noreply, %{state | standby: true, watch_ref: nil, repos: %{}}}
  end

  defp do_start_watch(state) do
    Logger.info("Starting GitRepository watch for namespace: #{state.namespace}")

    # First, list existing resources to sync
    case sync_existing_resources(state) do
      {:ok, new_state} ->
        # Then start watching for changes
        case start_watch(new_state) do
          {:ok, watch_state} ->
            {:noreply, watch_state}

          {:error, reason} ->
            Logger.error("Failed to start watch: #{inspect(reason)}")
            schedule_reconnect()
            {:noreply, new_state}
        end

      {:error, reason} ->
        Logger.error("Failed to sync existing resources: #{inspect(reason)}")
        schedule_reconnect()
        {:noreply, state}
    end
  end

  # Private functions

  defp sync_existing_resources(state) do
    case K8s.list_git_repositories(state.namespace) do
      {:ok, items} ->
        Logger.info("Found #{length(items)} existing GitRepository resources")
        repos = Enum.reduce(items, state.repos, &register_existing_resource/2)
        {:ok, %{state | repos: repos}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp register_existing_resource(resource, acc) do
    case start_worker_for_resource(resource) do
      {:ok, name} ->
        resource_version = get_in(resource, ["metadata", "resourceVersion"])
        Map.put(acc, name, resource_version)

      {:error, _reason} ->
        acc
    end
  end

  defp start_watch(state) do
    case K8s.watch_git_repositories(state.namespace) do
      {:ok, _stream} ->
        # The k8s library sends events to this process
        # Set watch_ref to indicate we're actively watching (used by readiness probe)
        {:ok, %{state | watch_ref: make_ref()}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_watch_event(%{"type" => type, "object" => object}, state) do
    name = get_in(object, ["metadata", "name"])
    resource_version = get_in(object, ["metadata", "resourceVersion"])

    Logger.debug("Watch event: type=#{type}, name=#{name}")

    case type do
      "ADDED" ->
        handle_added(object, state)

      "MODIFIED" ->
        handle_modified(object, state)

      "DELETED" ->
        handle_deleted(object, state)

      "BOOKMARK" ->
        # Update resource version for reconnect
        %{state | resource_version: resource_version}

      _ ->
        Logger.warning("Unknown watch event type: #{type}")
        state
    end
  end

  defp handle_added(resource, state) do
    name = get_in(resource, ["metadata", "name"])
    resource_version = get_in(resource, ["metadata", "resourceVersion"])

    if Map.has_key?(state.repos, name) do
      Logger.debug("Resource #{name} already tracked, ignoring ADDED event")
      state
    else
      case start_worker_for_resource(resource) do
        {:ok, ^name} ->
          %{state | repos: Map.put(state.repos, name, resource_version)}

        {:error, reason} ->
          Logger.error("Failed to start worker for #{name}: #{inspect(reason)}")
          state
      end
    end
  end

  defp handle_modified(resource, state) do
    name = get_in(resource, ["metadata", "name"])
    resource_version = get_in(resource, ["metadata", "resourceVersion"])

    # Check if spec changed (ignore status-only updates)
    if spec_changed?(resource, state) do
      Logger.info("Spec changed for #{name}, restarting worker")

      # Stop and restart worker with new config
      _ = Supervisor.stop_worker(name)

      case start_worker_for_resource(resource) do
        {:ok, ^name} ->
          %{state | repos: Map.put(state.repos, name, resource_version)}

        {:error, reason} ->
          Logger.error("Failed to restart worker for #{name}: #{inspect(reason)}")
          %{state | repos: Map.delete(state.repos, name)}
      end
    else
      # Just update tracked resource version
      %{state | repos: Map.put(state.repos, name, resource_version)}
    end
  end

  defp handle_deleted(resource, state) do
    name = get_in(resource, ["metadata", "name"])

    case Supervisor.stop_worker(name) do
      :ok ->
        Logger.info("Stopped worker for deleted resource: #{name}")

      {:error, :not_found} ->
        Logger.debug("Worker for #{name} not found (already stopped)")
    end

    %{state | repos: Map.delete(state.repos, name)}
  end

  defp start_worker_for_resource(resource) do
    name = get_in(resource, ["metadata", "name"])
    namespace = get_in(resource, ["metadata", "namespace"])
    spec = Map.get(resource, "spec", %{})

    config = %{
      name: name,
      namespace: namespace,
      url: Map.get(spec, "url"),
      branch: Map.get(spec, "branch", "main"),
      path: Map.get(spec, "path"),
      target_namespace: Map.get(spec, "targetNamespace", namespace),
      interval: parse_interval(Map.get(spec, "interval", "5m")),
      # Healing configuration
      suspend: Map.get(spec, "suspend", false),
      heal_policy: parse_heal_policy(Map.get(spec, "healPolicy", "auto")),
      heal_grace_period: parse_interval(Map.get(spec, "healGracePeriod"))
    }

    # Validate required fields
    if config.url do
      case Supervisor.start_worker(config) do
        {:ok, _pid} ->
          {:ok, name}

        {:error, {:already_started, _pid}} ->
          {:ok, name}

        {:error, reason} ->
          {:error, reason}
      end
    else
      Logger.error("GitRepository #{name} missing required field: url")
      {:error, :missing_url}
    end
  end

  defp spec_changed?(resource, state) do
    name = get_in(resource, ["metadata", "name"])
    generation = get_in(resource, ["metadata", "generation"])
    observed = get_in(resource, ["status", "observedGeneration"])

    # If generation != observedGeneration, spec changed
    cond do
      not Map.has_key?(state.repos, name) -> true
      is_nil(observed) -> true
      generation != observed -> true
      true -> false
    end
  end

  defp parse_interval(interval) when is_binary(interval) do
    # Parse duration strings like "5m", "1h", "30s"
    case Regex.run(~r/^(\d+)(s|m|h)$/, interval) do
      [_, num, "s"] -> String.to_integer(num) * 1_000
      [_, num, "m"] -> String.to_integer(num) * 60 * 1_000
      [_, num, "h"] -> String.to_integer(num) * 60 * 60 * 1_000
      # Default 5 minutes
      _ -> 5 * 60 * 1_000
    end
  end

  defp parse_interval(interval) when is_integer(interval), do: interval * 1_000
  defp parse_interval(nil), do: nil
  defp parse_interval(_), do: 5 * 60 * 1_000

  defp parse_heal_policy("auto"), do: :auto
  defp parse_heal_policy("manual"), do: :manual
  defp parse_heal_policy("notify"), do: :notify
  defp parse_heal_policy(_), do: :auto

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, @reconnect_delay)
  end
end
