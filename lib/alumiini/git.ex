defmodule Alumiini.Git do
  @moduledoc """
  Git operations via Rust Port.

  Communicates with alumiini-git binary using length-prefixed msgpack protocol.
  Provides crash isolation - if the Rust process crashes, we restart it
  without affecting other BEAM processes.
  """

  use GenServer
  require Logger

  @timeout 300_000  # 5 minutes for git operations

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sync a repository: clone if not exists, fetch+reset if exists.
  Returns {:ok, commit_sha} or {:error, reason}.
  """
  @spec sync(String.t(), String.t(), String.t(), integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def sync(url, branch, path, depth \\ 1) do
    GenServer.call(__MODULE__, {:sync, url, branch, path, depth}, @timeout)
  end

  @doc """
  List YAML files in a directory.
  Returns {:ok, [filename]} or {:error, reason}.
  """
  @spec files(String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def files(path, subpath \\ nil) do
    GenServer.call(__MODULE__, {:files, path, subpath}, @timeout)
  end

  @doc """
  Read a file from the repository.
  Returns {:ok, content} or {:error, reason}.
  Content is the raw binary (base64 decoded).
  """
  @spec read(String.t(), String.t()) ::
          {:ok, binary()} | {:error, String.t()}
  def read(path, file) do
    GenServer.call(__MODULE__, {:read, path, file}, @timeout)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    port = open_port()
    {:ok, %{port: port, caller: nil}}
  end

  @impl true
  def handle_call({:sync, url, branch, path, depth}, from, state) do
    request = %{"op" => "sync", "url" => url, "branch" => branch, "path" => path, "depth" => depth}
    send_request(state.port, request)
    {:noreply, %{state | caller: from}}
  end

  @impl true
  def handle_call({:files, path, subpath}, from, state) do
    request = %{"op" => "files", "path" => path, "subpath" => subpath}
    send_request(state.port, request)
    {:noreply, %{state | caller: from}}
  end

  @impl true
  def handle_call({:read, path, file}, from, state) do
    request = %{"op" => "read", "path" => path, "file" => file}
    send_request(state.port, request)
    {:noreply, %{state | caller: from}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, caller: caller} = state) do
    response = parse_response(data)
    if caller, do: GenServer.reply(caller, response)
    {:noreply, %{state | caller: nil}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Git port exited with status #{status}, restarting")

    # Reply with error if there was a pending request
    if state.caller do
      GenServer.reply(state.caller, {:error, "git process exited unexpectedly"})
    end

    # Restart the port
    new_port = open_port()
    {:noreply, %{state | port: new_port, caller: nil}}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    Port.close(port)
  end

  # Private functions

  defp open_port do
    binary_path = git_binary_path()

    unless File.exists?(binary_path) do
      raise "alumiini-git binary not found at #{binary_path}"
    end

    Port.open({:spawn_executable, binary_path}, [
      :binary,
      {:packet, 4},  # 4-byte big-endian length prefix
      :exit_status,
      :use_stdio
    ])
  end

  defp git_binary_path do
    # Check for dev path first, then priv
    dev_path = Path.join([File.cwd!(), "alumiini-git", "target", "release", "alumiini-git"])

    if File.exists?(dev_path) do
      dev_path
    else
      Application.app_dir(:alumiini, "priv/alumiini-git")
    end
  end

  defp send_request(port, request) do
    data = Msgpax.pack!(request)
    Port.command(port, data)
  end

  defp parse_response(data) do
    case Msgpax.unpack!(data) do
      %{"ok" => value} when is_binary(value) ->
        # Check if this might be base64 from a read operation
        # We handle decoding in the caller for read operations
        {:ok, value}

      %{"ok" => files} when is_list(files) ->
        {:ok, files}

      %{"err" => reason} ->
        {:error, reason}

      other ->
        Logger.error("Unexpected response from git port: #{inspect(other)}")
        {:error, "unexpected response format"}
    end
  end

  @doc """
  Decode base64 content from a read operation.
  """
  @spec decode_content(String.t()) :: {:ok, binary()} | {:error, :invalid_base64}
  def decode_content(base64_content) do
    case Base.decode64(base64_content) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, :invalid_base64}
    end
  end
end
