defmodule Nopea.Supervisor do
  @moduledoc """
  DynamicSupervisor for managing Worker processes.

  One Worker per GitRepository resource.
  Automatic restart on crash.

  When `cluster_enabled` is true, delegates to `Nopea.DistributedSupervisor`
  for cluster-wide process management with automatic failover.
  """

  use DynamicSupervisor
  require Logger

  alias Nopea.{DistributedRegistry, DistributedSupervisor, Metrics, Worker}

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Supervisor started")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a worker for the given repository config.

  In cluster mode, uses Horde.DynamicSupervisor for distributed supervision.
  """
  @spec start_worker(map()) :: {:ok, pid()} | {:error, term()}
  def start_worker(config) do
    if cluster_enabled?() do
      start_worker_distributed(config)
    else
      start_worker_local(config)
    end
  end

  defp start_worker_local(config) do
    child_spec = {Worker, config}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Started worker for repo: #{config.name}")
        emit_worker_count()
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:error, {:already_started, pid}}

      {:error, reason} = error ->
        Logger.error("Failed to start worker for repo #{config.name}: #{inspect(reason)}")
        error
    end
  end

  defp start_worker_distributed(config) do
    child_spec = %{
      id: config.name,
      start: {Worker, :start_link, [config]}
    }

    case DistributedSupervisor.start_child(child_spec) do
      {:ok, pid} ->
        Logger.info("Started distributed worker for repo: #{config.name}")
        emit_worker_count()
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:error, {:already_started, pid}}

      {:error, reason} = error ->
        Logger.error(
          "Failed to start distributed worker for repo #{config.name}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Stops the worker for the given repository name.

  In cluster mode, uses Horde.DynamicSupervisor for termination.
  """
  @spec stop_worker(String.t()) :: :ok | {:error, :not_found}
  def stop_worker(repo_name) do
    if cluster_enabled?() do
      stop_worker_distributed(repo_name)
    else
      stop_worker_local(repo_name)
    end
  end

  defp stop_worker_local(repo_name) do
    case Worker.whereis(repo_name) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Logger.info("Stopped worker for repo: #{repo_name}")
        emit_worker_count()
        :ok
    end
  end

  defp stop_worker_distributed(repo_name) do
    case Worker.whereis(repo_name) do
      nil ->
        {:error, :not_found}

      pid ->
        DistributedSupervisor.terminate_child(pid)
        Logger.info("Stopped distributed worker for repo: #{repo_name}")
        emit_worker_count()
        :ok
    end
  end

  defp emit_worker_count do
    count = length(list_workers())
    Metrics.set_active_workers(count)
  end

  @doc """
  Lists all active workers.
  Returns list of {repo_name, pid} tuples.

  In cluster mode, queries the distributed registry.
  """
  @spec list_workers() :: [{String.t(), pid()}]
  def list_workers do
    if cluster_enabled?() do
      DistributedRegistry.list_all()
    else
      Registry.select(Nopea.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    end
  end

  @doc """
  Gets the pid for a worker by repo name.
  """
  @spec get_worker(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_worker(repo_name) do
    case Worker.whereis(repo_name) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  # Check if BEAM clustering is enabled
  defp cluster_enabled? do
    Application.get_env(:nopea, :cluster_enabled, false)
  end
end
