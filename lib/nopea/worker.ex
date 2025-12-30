defmodule Nopea.Worker do
  @moduledoc """
  GenServer worker for a single GitRepository.

  Responsibilities:
  - Git clone/fetch operations via Rust Port
  - Periodic polling for changes
  - Webhook handling
  - K8s apply operations
  - Status updates to GitRepository CRD
  """

  use GenServer
  require Logger

  alias Nopea.{Applier, Cache, Drift, Events, Git, K8s, Metrics}
  alias Nopea.Events.Emitter

  defstruct [
    :config,
    :poll_timer,
    :reconcile_timer,
    :last_commit,
    :last_sync,
    status: :initializing
  ]

  @type status :: :initializing | :syncing | :synced | :failed

  @type t :: %__MODULE__{
          config: map(),
          poll_timer: reference() | nil,
          reconcile_timer: reference() | nil,
          last_commit: String.t() | nil,
          last_sync: DateTime.t() | nil,
          status: status()
        }

  @repo_base_path "/tmp/nopea/repos"

  # Client API

  @doc """
  Starts a worker with the given config.
  """
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: via_tuple(config.name))
  end

  @doc """
  Returns the current state of a worker.
  """
  @spec get_state(pid()) :: t()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Triggers an immediate sync.
  """
  @spec sync_now(pid()) :: :ok | {:error, term()}
  def sync_now(pid) do
    GenServer.call(pid, :sync_now, 300_000)
  end

  @doc """
  Looks up a worker by repo name.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(repo_name) do
    case Registry.lookup(Nopea.Registry, repo_name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Private helper for via tuple
  defp via_tuple(repo_name) do
    {:via, Registry, {Nopea.Registry, repo_name}}
  end

  # Server Callbacks

  @impl true
  def init(config) do
    Logger.info("Worker starting for repo: #{config.name}")

    state = %__MODULE__{
      config: config,
      status: :initializing
    }

    # Schedule initial sync
    send(self(), :startup_sync)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    case do_sync(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        Logger.error("Sync failed for #{state.config.name}: #{inspect(reason)}")
        {:reply, error, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_info(:startup_sync, state) do
    Logger.info("Performing startup sync for: #{state.config.name}")

    new_state =
      case do_sync(state) do
        {:ok, synced_state} ->
          schedule_poll(synced_state)
          schedule_reconcile(synced_state)
          synced_state

        {:error, reason} ->
          Logger.warning("Startup sync failed for #{state.config.name}: #{inspect(reason)}")
          update_crd_status(state, :failed, "Startup sync failed: #{inspect(reason)}")
          schedule_poll(state)
          %{state | status: :failed}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    Logger.debug("Poll triggered for: #{state.config.name}")

    new_state =
      case check_for_changes(state) do
        {:changed, commit} ->
          Logger.info("Changes detected for #{state.config.name}, commit: #{commit}")

          case do_sync(state) do
            {:ok, synced_state} -> synced_state
            {:error, _} -> %{state | status: :failed}
          end

        :unchanged ->
          state
      end

    {:noreply, schedule_poll(new_state)}
  end

  @impl true
  def handle_info(:reconcile, state) do
    Logger.debug("Reconcile triggered for: #{state.config.name}")

    new_state =
      case reconcile_with_drift_detection(state) do
        {:ok, drift_count, apply_count} ->
          if drift_count > 0 do
            Logger.info(
              "Reconcile healed #{drift_count} drifted resources for #{state.config.name}"
            )
          end

          if apply_count > 0, do: %{state | status: :synced}, else: state

        {:error, reason} ->
          Logger.warning("Reconcile failed for #{state.config.name}: #{inspect(reason)}")
          state
      end

    {:noreply, schedule_reconcile(new_state)}
  end

  @impl true
  def handle_info({:webhook, commit}, state) do
    Logger.info("Webhook received for #{state.config.name}, commit: #{commit}")

    new_state =
      case do_sync(state) do
        {:ok, synced_state} -> synced_state
        {:error, _} -> %{state | status: :failed}
      end

    {:noreply, new_state}
  end

  # Private functions

  defp do_sync(state) do
    config = state.config
    repo_path = repo_path(config.name)
    start_time = System.monotonic_time(:millisecond)

    # Emit metrics start
    metrics_start = Metrics.emit_sync_start(%{repo: config.name})

    Logger.info("Syncing repo: #{config.name} from #{config.url}")
    update_crd_status(state, :syncing, "Syncing from git")

    with {:ok, commit_sha} <- Git.sync(config.url, config.branch, repo_path),
         {:ok, count} <- apply_manifests_from_repo(state, repo_path) do
      now = DateTime.utc_now()
      duration_ms = System.monotonic_time(:millisecond) - start_time

      new_state = %{
        state
        | status: :synced,
          last_commit: commit_sha,
          last_sync: now
      }

      # Update cache if available
      if Cache.available?() do
        Cache.put_sync_state(config.name, %{
          last_sync: now,
          last_commit: commit_sha,
          status: :synced
        })
      end

      # Update CRD status
      update_crd_status(new_state, :synced, "Applied #{count} manifests")

      # Emit CDEvent
      emit_sync_event(state, new_state, count, duration_ms)

      # Emit metrics success
      Metrics.emit_sync_stop(metrics_start, %{repo: config.name, status: :ok})

      Logger.info("Sync completed for #{config.name}: commit=#{commit_sha}, manifests=#{count}")
      {:ok, new_state}
    else
      {:error, reason} = error ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        Logger.error("Sync failed for #{config.name}: #{inspect(reason)}")
        update_crd_status(state, :failed, "Sync failed: #{inspect(reason)}")

        # Emit failure CDEvent
        emit_failure_event(state, reason, duration_ms)

        # Emit metrics failure
        Metrics.emit_sync_error(metrics_start, %{repo: config.name, error: error_type(reason)})

        error
    end
  end

  defp error_type(reason) when is_atom(reason), do: reason
  defp error_type({type, _}), do: type
  defp error_type(_), do: :unknown

  defp apply_manifests_from_repo(state, repo_path) do
    config = state.config
    manifest_path = if config.path, do: Path.join(repo_path, config.path), else: repo_path

    with {:ok, files} <- list_manifest_files(repo_path, config.path),
         {:ok, manifests} <- read_and_parse_manifests(repo_path, config.path, files) do
      Logger.info("Found #{length(manifests)} manifests in #{manifest_path}")

      case K8s.apply_manifests(manifests, config.target_namespace) do
        {:ok, count} ->
          # Store last-applied manifests for drift detection
          store_last_applied(config.name, manifests)
          {:ok, count}

        error ->
          error
      end
    end
  end

  # Store normalized manifests for drift detection
  defp store_last_applied(repo_name, manifests) do
    if Cache.available?() do
      Enum.each(manifests, fn manifest ->
        resource_key = Applier.resource_key(manifest)
        normalized = Drift.normalize(manifest)
        Cache.put_last_applied(repo_name, resource_key, normalized)
      end)
    end
  end

  # Reconcile with drift detection - only re-apply changed resources
  defp reconcile_with_drift_detection(state) do
    config = state.config

    # Check if repository is suspended
    if config[:suspend] do
      Logger.debug("Repository #{config.name} is suspended, skipping reconcile")
      {:ok, 0, 0}
    else
      do_reconcile(state)
    end
  end

  defp do_reconcile(state) do
    config = state.config
    repo_path = repo_path(config.name)

    if File.exists?(repo_path) do
      with {:ok, files} <- list_manifest_files(repo_path, config.path),
           {:ok, manifests} <- read_and_parse_manifests(repo_path, config.path, files) do
        reconcile_manifests(state, manifests)
      end
    else
      {:error, :repo_not_cloned}
    end
  end

  defp reconcile_manifests(state, manifests) do
    config = state.config
    {to_apply, _unchanged} = detect_drifted_manifests(config.name, manifests)

    Logger.debug("Drift detection for #{config.name}: #{length(to_apply)} need apply")

    if Enum.empty?(to_apply) do
      {:ok, 0, 0}
    else
      apply_drifted_manifests(state, to_apply)
    end
  end

  defp apply_drifted_manifests(state, to_apply) do
    config = state.config
    {to_heal, skipped} = filter_for_healing(to_apply, config)

    # Emit CDEvents for ALL detected drift (including skipped)
    emit_drift_events(state, to_apply, skipped)

    if Enum.empty?(to_heal) do
      Logger.info("All #{length(to_apply)} drifted resources have healing suspended")
      {:ok, length(to_apply), 0}
    else
      heal_drifted_resources(config, to_heal)
    end
  end

  defp heal_drifted_resources(config, to_heal) do
    manifests_to_apply = Enum.map(to_heal, fn {manifest, _type, _live} -> manifest end)

    case K8s.apply_manifests(manifests_to_apply, config.target_namespace) do
      {:ok, count} ->
        store_last_applied(config.name, manifests_to_apply)
        clear_healed_drift_timestamps(config.name, to_heal)
        {:ok, length(to_heal), count}

      {:error, _} = error ->
        error
    end
  end

  # Detect which manifests have drifted using full three-way comparison
  # Returns {to_apply, unchanged} where to_apply is [{manifest, drift_type, live}, ...]
  # The live resource is included for break-glass annotation checking
  defp detect_drifted_manifests(repo_name, manifests) do
    if Cache.available?() do
      {to_apply, unchanged} =
        Enum.reduce(manifests, {[], []}, &classify_manifest_drift(repo_name, &1, &2))

      {Enum.reverse(to_apply), Enum.reverse(unchanged)}
    else
      # No cache - treat all as needing apply (new resources, no live)
      to_apply = Enum.map(manifests, &{&1, :new_resource, nil})
      {to_apply, []}
    end
  end

  defp classify_manifest_drift(repo_name, manifest, {apply_acc, unchanged_acc}) do
    case Drift.check_manifest_drift_with_live(repo_name, manifest) do
      {:no_drift, _live} ->
        resource_key = Applier.resource_key(manifest)
        clear_drift_timestamp(repo_name, resource_key)
        {apply_acc, [manifest | unchanged_acc]}

      {:new_resource, nil} ->
        {[{manifest, :new_resource, nil} | apply_acc], unchanged_acc}

      {:needs_apply, live} ->
        {[{manifest, :needs_apply, live} | apply_acc], unchanged_acc}

      {{:git_change, _diff}, live} ->
        {[{manifest, :git_change, live} | apply_acc], unchanged_acc}

      {{:manual_drift, _diff}, live} ->
        {[{manifest, :manual_drift, live} | apply_acc], unchanged_acc}

      {{:conflict, _diff}, live} ->
        {[{manifest, :conflict, live} | apply_acc], unchanged_acc}
    end
  end

  # Filter drifted manifests based on heal_policy, grace period, and break-glass annotations
  # Returns {to_heal, skipped} where each is [{manifest, drift_type, live}, ...]
  defp filter_for_healing(to_apply, config) do
    heal_policy = config[:heal_policy] || :auto
    grace_period_ms = config[:heal_grace_period]
    repo_name = config.name

    Enum.split_with(to_apply, fn {manifest, drift_type, live} ->
      should_heal_resource?(drift_type, manifest, live, heal_policy, grace_period_ms, repo_name)
    end)
  end

  defp should_heal_resource?(drift_type, manifest, live, heal_policy, grace_period_ms, repo_name) do
    resource_key = Applier.resource_key(manifest)

    case drift_type do
      :new_resource ->
        true

      :needs_apply ->
        true

      :git_change ->
        should_heal_git_change?(live, repo_name, resource_key)

      :manual_drift ->
        should_heal_manual_drift?(heal_policy, grace_period_ms, repo_name, resource_key, live)

      :conflict ->
        should_heal_manual_drift?(heal_policy, grace_period_ms, repo_name, resource_key, live)
    end
  end

  defp should_heal_git_change?(live, repo_name, resource_key) do
    if healing_suspended?(live) do
      Logger.warning("Git change blocked by suspend-heal annotation: #{resource_key}")
      false
    else
      clear_drift_timestamp(repo_name, resource_key)
      true
    end
  end

  # Determine if manual drift should be healed based on policy, grace period, and annotation
  defp should_heal_manual_drift?(heal_policy, grace_period_ms, repo_name, resource_key, live) do
    case heal_policy do
      :auto ->
        # Check break-glass annotation first
        if healing_suspended?(live) do
          false
        else
          # Check grace period if configured
          grace_period_elapsed?(grace_period_ms, repo_name, resource_key)
        end

      :manual ->
        # Never auto-heal, operator must intervene
        false

      :notify ->
        # Same as manual, but with webhook (future)
        false
    end
  end

  # Check if grace period has elapsed since drift was first detected
  defp grace_period_elapsed?(nil, _repo_name, _resource_key) do
    # No grace period configured, heal immediately
    true
  end

  defp grace_period_elapsed?(grace_period_ms, repo_name, resource_key) do
    if Cache.available?() do
      first_seen = Cache.record_drift_first_seen(repo_name, resource_key)
      elapsed_ms = DateTime.diff(DateTime.utc_now(), first_seen, :millisecond)

      if elapsed_ms >= grace_period_ms do
        Logger.info("Grace period elapsed for #{resource_key}, healing drift")
        true
      else
        remaining_s = div(grace_period_ms - elapsed_ms, 1000)
        Logger.debug("Grace period: #{remaining_s}s remaining for #{resource_key}")
        false
      end
    else
      # No cache, heal immediately
      true
    end
  end

  # Clear drift timestamp after healing or when drift resolves
  defp clear_drift_timestamp(repo_name, resource_key) do
    if Cache.available?() do
      Cache.clear_drift_first_seen(repo_name, resource_key)
    end
  end

  # Clear drift timestamps for all healed resources
  defp clear_healed_drift_timestamps(repo_name, healed) do
    if Cache.available?() do
      Enum.each(healed, fn {manifest, _type, _live} ->
        resource_key = Applier.resource_key(manifest)
        Cache.clear_drift_first_seen(repo_name, resource_key)
      end)
    end
  end

  # Check if a live resource has the break-glass annotation
  defp healing_suspended?(nil), do: false
  defp healing_suspended?(live), do: Drift.healing_suspended?(live)

  # Emit CDEvents for drifted resources with their drift types
  # skipped contains resources that have healing suspended
  defp emit_drift_events(state, to_apply, skipped) do
    config = state.config
    skipped_keys = MapSet.new(skipped, fn {m, _, _} -> Applier.resource_key(m) end)

    Enum.each(to_apply, fn {manifest, drift_type, _live} ->
      resource_key = Applier.resource_key(manifest)
      action = if MapSet.member?(skipped_keys, resource_key), do: :skipped, else: :healed

      # Emit Prometheus metrics
      Metrics.emit_drift_detected(%{repo: config.name, resource: resource_key})

      if action == :healed do
        Metrics.emit_drift_healed(%{repo: config.name, resource: resource_key})
      end

      event =
        Events.drift_detected(config.name, %{
          resource_key: resource_key,
          drift_type: drift_type,
          namespace: config.target_namespace,
          commit: state.last_commit,
          action: action
        })

      maybe_emit(event)
    end)
  end

  defp list_manifest_files(repo_path, subpath) do
    case Git.files(repo_path, subpath) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, {:list_files_failed, reason}}
    end
  end

  defp read_and_parse_manifests(repo_path, subpath, files) do
    results =
      Enum.map(files, fn file ->
        file_path = if subpath, do: Path.join(subpath, file), else: file

        with {:ok, base64_content} <- Git.read(repo_path, file_path),
             {:ok, content} <- Git.decode_content(base64_content),
             {:ok, manifests} <- Applier.parse_manifests(content) do
          {:ok, manifests}
        else
          {:error, reason} -> {:error, {file, reason}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      manifests =
        results
        |> Enum.flat_map(fn {:ok, m} -> m end)

      {:ok, manifests}
    else
      {:error, {:parse_failed, errors}}
    end
  end

  defp check_for_changes(state) do
    config = state.config
    repo_path = repo_path(config.name)

    if File.exists?(repo_path) do
      check_git_changes(config, repo_path, state.last_commit)
    else
      :unchanged
    end
  end

  defp check_git_changes(config, repo_path, last_commit) do
    case Git.sync(config.url, config.branch, repo_path) do
      {:ok, commit_sha} when commit_sha != last_commit -> {:changed, commit_sha}
      {:ok, _same_commit} -> :unchanged
      {:error, _reason} -> :unchanged
    end
  end

  defp update_crd_status(state, phase, message) do
    config = state.config

    if config[:namespace] do
      status = K8s.build_status(phase, state.last_commit, state.last_sync, message)

      case K8s.update_status(config.name, config.namespace, status) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to update CRD status: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp repo_path(repo_name) do
    # Sanitize repo name for filesystem
    safe_name = String.replace(repo_name, ~r/[^a-zA-Z0-9_-]/, "_")
    Path.join(@repo_base_path, safe_name)
  end

  defp schedule_poll(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    timer = Process.send_after(self(), :poll, state.config.interval)
    %{state | poll_timer: timer}
  end

  defp schedule_reconcile(state) do
    if state.reconcile_timer, do: Process.cancel_timer(state.reconcile_timer)
    # Reconcile less frequently than poll (2x interval)
    timer = Process.send_after(self(), :reconcile, state.config.interval * 2)
    %{state | reconcile_timer: timer}
  end

  # CDEvents emission helpers

  defp emit_sync_event(old_state, new_state, manifest_count, duration_ms) do
    config = new_state.config

    event_opts = %{
      commit: new_state.last_commit,
      namespace: config.target_namespace,
      manifest_count: manifest_count,
      duration_ms: duration_ms,
      source_url: config.url
    }

    event =
      if old_state.last_commit == nil do
        # First sync - service deployed
        Events.service_deployed(config.name, event_opts)
      else
        # Subsequent sync - service upgraded
        Events.service_upgraded(
          config.name,
          Map.put(event_opts, :previous_commit, old_state.last_commit)
        )
      end

    maybe_emit(event)
  end

  defp emit_failure_event(state, reason, duration_ms) do
    config = state.config

    event =
      Events.sync_failed(config.name, %{
        namespace: config.target_namespace,
        error: reason,
        commit: state.last_commit,
        duration_ms: duration_ms
      })

    maybe_emit(event)
  end

  defp maybe_emit(event) do
    # Check if emitter is running
    case Process.whereis(Nopea.Events.Emitter) do
      nil ->
        :ok

      pid ->
        Emitter.emit(pid, event)
    end
  end
end
