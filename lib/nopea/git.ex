defmodule Nopea.Git do
  @moduledoc """
  Git operations via Rust Port.

  Communicates with nopea-git binary using length-prefixed msgpack protocol.
  Provides crash isolation - if the Rust process crashes, we restart it
  without affecting other BEAM processes.
  """

  @behaviour Nopea.Git.Behaviour

  use GenServer
  require Logger

  # 5 minutes for git operations
  @timeout 300_000

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

  @typedoc "Commit information from HEAD"
  @type commit_info :: %{
          sha: String.t(),
          author: String.t(),
          email: String.t(),
          message: String.t(),
          timestamp: integer()
        }

  @doc """
  Get HEAD commit information.
  Returns {:ok, commit_info} or {:error, reason}.
  """
  @spec head(String.t()) :: {:ok, commit_info()} | {:error, String.t()}
  def head(path) do
    GenServer.call(__MODULE__, {:head, path}, @timeout)
  end

  @doc """
  Checkout (hard reset) to a specific commit SHA.

  **Warning**: This performs a destructive hard reset that:
  - Discards all uncommitted changes in the working directory
  - Leaves the repository in a detached HEAD state

  The detached HEAD state is intentional for rollback scenarios where we
  want to deploy a specific commit without modifying branch pointers.

  Returns `{:ok, sha}` or `{:error, reason}`.
  """
  @spec checkout(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def checkout(path, sha) do
    GenServer.call(__MODULE__, {:checkout, path, sha}, @timeout)
  end

  @doc """
  Query remote for the latest commit SHA of a branch without fetching.
  Useful for cheap polling to detect new commits.
  Returns {:ok, sha} or {:error, reason}.
  """
  @spec ls_remote(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def ls_remote(url, branch) do
    GenServer.call(__MODULE__, {:ls_remote, url, branch}, @timeout)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    case open_port() do
      {:ok, port} ->
        {:ok, %{port: port, caller: nil}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:sync, url, branch, path, depth}, from, state) do
    request = %{
      "op" => "sync",
      "url" => url,
      "branch" => branch,
      "path" => path,
      "depth" => depth
    }

    case send_request(state.port, request) do
      :ok -> {:noreply, %{state | caller: from}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:files, path, subpath}, from, state) do
    request = %{"op" => "files", "path" => path, "subpath" => subpath}

    case send_request(state.port, request) do
      :ok -> {:noreply, %{state | caller: from}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:read, path, file}, from, state) do
    request = %{"op" => "read", "path" => path, "file" => file}

    case send_request(state.port, request) do
      :ok -> {:noreply, %{state | caller: from}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:head, path}, from, state) do
    request = %{"op" => "head", "path" => path}

    case send_request(state.port, request) do
      :ok -> {:noreply, %{state | caller: from}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:checkout, path, sha}, from, state) do
    request = %{"op" => "checkout", "path" => path, "sha" => sha}

    case send_request(state.port, request) do
      :ok -> {:noreply, %{state | caller: from}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:ls_remote, url, branch}, from, state) do
    request = %{"op" => "lsremote", "url" => url, "branch" => branch}

    case send_request(state.port, request) do
      :ok -> {:noreply, %{state | caller: from}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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
    case open_port() do
      {:ok, new_port} ->
        {:noreply, %{state | port: new_port, caller: nil}}

      {:error, reason} ->
        Logger.error("Failed to restart git port: #{inspect(reason)}")
        {:stop, {:port_restart_failed, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    Port.close(port)
  end

  # Private functions

  defp open_port do
    binary_path = git_binary_path()

    if File.exists?(binary_path) do
      port =
        Port.open({:spawn_executable, binary_path}, [
          :binary,
          {:packet, 4},
          :exit_status,
          :use_stdio
        ])

      {:ok, port}
    else
      Logger.error("nopea-git binary not found at #{binary_path}")
      {:error, {:binary_not_found, binary_path}}
    end
  end

  defp git_binary_path do
    # Check for dev path first, then priv
    dev_path = Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])

    if File.exists?(dev_path) do
      dev_path
    else
      Application.app_dir(:nopea, "priv/nopea-git")
    end
  end

  defp send_request(port, request) do
    case Msgpax.pack(request) do
      {:ok, data} ->
        Port.command(port, data)
        :ok

      {:error, reason} ->
        Logger.error("Failed to pack msgpack request: #{inspect(reason)}")
        {:error, {:msgpack_pack_error, reason}}
    end
  end

  defp parse_response(data) do
    case Msgpax.unpack(data) do
      {:ok, response} -> parse_git_response(response)
      {:error, reason} -> handle_msgpack_error(reason)
    end
  end

  defp parse_git_response(%{"ok" => value}) when is_binary(value), do: {:ok, value}
  defp parse_git_response(%{"ok" => files}) when is_list(files), do: {:ok, files}

  defp parse_git_response(%{
         "ok" => %{
           "sha" => sha,
           "author" => author,
           "email" => email,
           "message" => msg,
           "timestamp" => ts
         }
       })
       when is_binary(sha) and is_binary(author) and is_binary(email) and is_binary(msg) and
              is_integer(ts) do
    {:ok, %{sha: sha, author: author, email: email, message: msg, timestamp: ts}}
  end

  defp parse_git_response(%{"err" => reason}), do: {:error, reason}

  defp parse_git_response(other) do
    Logger.error("Unexpected response from git port: #{inspect(other)}")
    {:error, "unexpected response format"}
  end

  defp handle_msgpack_error(reason) do
    Logger.error("Failed to unpack msgpack response: #{inspect(reason)}")
    {:error, {:msgpack_error, reason}}
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
