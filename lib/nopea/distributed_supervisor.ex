defmodule Nopea.DistributedSupervisor do
  @moduledoc """
  Distributed dynamic supervisor using Horde.

  Manages child processes across the cluster. Children started via this supervisor
  are automatically distributed to available nodes and restarted on surviving nodes
  if their host node dies.

  ## Usage

  Start a child process that will be distributed across the cluster:

      child_spec = %{
        id: "my-worker",
        start: {MyWorker, :start_link, [args]}
      }

      {:ok, pid} = DistributedSupervisor.start_child(child_spec)

  ## How It Works

  Uses Horde.DynamicSupervisor with Delta CRDTs for conflict-free replication.
  When a new child is started, Horde decides which node should host it based on
  current load distribution.

  If a node crashes, Horde detects this and restarts orphaned children on
  surviving nodes. This provides automatic failover without any custom logic.

  ## Integration with DistributedRegistry

  For best results, combine with `DistributedRegistry` for process naming:

      child_spec = %{
        id: repo_name,
        start: {Nopea.Worker, :start_link, [
          %{name: repo_name, url: url, branch: branch, ...}
        ]}
      }

  The Worker automatically uses DistributedRegistry when `cluster_enabled` is true.
  This ensures the worker can be found from any node in the cluster.
  """

  use Horde.DynamicSupervisor

  @doc """
  Starts the distributed supervisor.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Horde.DynamicSupervisor.start_link(
      __MODULE__,
      [strategy: :one_for_one, members: :auto],
      name: name
    )
  end

  @impl true
  def init(init_arg) do
    [strategy: strategy, members: members] = init_arg
    Horde.DynamicSupervisor.init(strategy: strategy, members: members)
  end

  @doc """
  Starts a child process under the distributed supervisor.

  The child will be started on one of the nodes in the cluster. Horde
  automatically selects the node based on current distribution.

  ## Example

      child_spec = %{
        id: "my-worker",
        start: {MyWorker, :start_link, [[name: DistributedRegistry.via("my-worker")]]}
      }

      {:ok, pid} = DistributedSupervisor.start_child(child_spec)

  """
  @spec start_child(Supervisor.child_spec() | {module(), term()} | module()) ::
          {:ok, pid()} | {:error, term()}
  def start_child(child_spec) do
    Horde.DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Terminates a child process by its PID or ID.

  Returns `:ok` whether the child existed or not (idempotent).

  ## Example

      # By PID (preferred)
      DistributedSupervisor.terminate_child(pid)

      # By ID (searches through children)
      DistributedSupervisor.terminate_child("my-worker")

  Note: This function is idempotent - it returns `:ok` even if the child
  was already terminated or doesn't exist.
  """
  @spec terminate_child(pid() | term()) :: :ok
  def terminate_child(pid) when is_pid(pid) do
    case Horde.DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  def terminate_child(child_id) do
    # Find the child's pid first by searching through children
    children = which_children()

    case Enum.find(children, fn {id, _pid, _type, _modules} -> id == child_id end) do
      {_id, pid, _type, _modules} when is_pid(pid) ->
        terminate_child(pid)

      _ ->
        :ok
    end
  end

  @doc """
  Returns a list of all children supervised by this supervisor.

  Each child is represented as `{id, pid, type, modules}`.
  """
  @spec which_children() :: [
          {term(), pid() | :restarting | :undefined, :worker | :supervisor, [module()] | :dynamic}
        ]
  def which_children do
    Horde.DynamicSupervisor.which_children(__MODULE__)
  end

  @doc """
  Returns counts of children in various states.

  Returns a map with keys:
  - `:specs` - Total number of children
  - `:active` - Number of running children
  - `:supervisors` - Number of supervisor children
  - `:workers` - Number of worker children
  """
  @spec count_children() :: map()
  def count_children do
    Horde.DynamicSupervisor.count_children(__MODULE__)
  end
end
