defmodule Nopea.DistributedRegistry do
  @moduledoc """
  Distributed process registry using Horde.

  Provides cluster-wide unique process registration. When a process is registered
  under a key, that key is reserved across all nodes in the cluster.

  ## Usage

  The recommended way to use this registry is via tuples:

      # Start a GenServer with distributed registration
      GenServer.start_link(MyWorker, args, name: DistributedRegistry.via("my-app"))

      # Find the Worker anywhere in the cluster
      {:ok, pid} = DistributedRegistry.lookup("my-app")

      # Or use GenServer.whereis
      pid = GenServer.whereis(DistributedRegistry.via("my-app"))

  ## How It Works

  Uses Horde.Registry with Delta CRDTs for conflict-free replication.
  When nodes join/leave, the registry state syncs automatically without
  needing a central coordinator.

  In case of a network partition, Horde uses "last write wins" semantics
  for conflict resolution when the partition heals.
  """

  use Horde.Registry

  @type key :: String.t()

  @doc """
  Starts the distributed registry.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Horde.Registry.start_link(
      __MODULE__,
      [keys: :unique, name: name, members: :auto],
      name: name
    )
  end

  @impl true
  def init(init_arg) do
    [keys: keys, name: _name, members: members] = init_arg
    Horde.Registry.init(keys: keys, members: members)
  end

  @doc """
  Returns a via tuple for use with GenServer.start_link/3.

  This is the recommended way to register processes with the distributed registry.

  ## Example

      # Start a worker with distributed registration
      GenServer.start_link(MyWorker, args, name: DistributedRegistry.via("my-app"))

      # The process is now registered cluster-wide under "my-app"
      # It can be found from any node:
      {:ok, pid} = DistributedRegistry.lookup("my-app")

  """
  @spec via(key()) :: {:via, module(), {module(), key()}}
  def via(key) do
    {:via, Horde.Registry, {__MODULE__, key}}
  end

  @doc """
  Registers the calling process under a unique key.

  Returns `:ok` if successful, or `{:error, {:already_registered, pid}}`
  if another process already owns this key.

  NOTE: This registers the calling process (self()). For most use cases,
  prefer using `via/1` with GenServer.start_link instead.

  ## Example

      def init(args) do
        # Register this process under its repo name
        DistributedRegistry.register(args.repo_name)
        {:ok, %{repo: args.repo_name}}
      end

  """
  @spec register(key()) :: :ok | {:error, {:already_registered, pid()}}
  def register(key) do
    case Horde.Registry.register(__MODULE__, key, nil) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, existing_pid}} ->
        {:error, {:already_registered, existing_pid}}
    end
  end

  @doc """
  Looks up a process by key.

  Returns `{:ok, pid}` if found, or `{:error, :not_found}` if no process
  is registered under this key.

  ## Example

      case DistributedRegistry.lookup("my-app") do
        {:ok, pid} -> GenServer.call(pid, :get_status)
        {:error, :not_found} -> {:error, :worker_not_running}
      end

  """
  @spec lookup(key()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(key) do
    case Horde.Registry.lookup(__MODULE__, key) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Unregisters a key.

  Returns `:ok` whether the key existed or not (idempotent).

  Note: Processes registered via `via/1` are automatically unregistered
  when they terminate. You typically don't need to call this manually.
  """
  @spec unregister(key()) :: :ok
  def unregister(key) do
    Horde.Registry.unregister(__MODULE__, key)
  end

  @doc """
  Lists all registered keys and their PIDs.

  Returns a list of `{key, pid}` tuples.

  ## Example

      DistributedRegistry.list_all()
      # => [{"repo-a", #PID<0.123.0>}, {"repo-b", #PID<0.456.0>}]

  """
  @spec list_all() :: [{key(), pid()}]
  def list_all do
    Horde.Registry.select(__MODULE__, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end
end
