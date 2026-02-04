defmodule Nopea.Sync.Executor do
  @moduledoc """
  Executes the git-to-kubernetes sync cycle.

  This module contains the core sync logic extracted from Worker:
  1. Git sync (clone or fetch+reset)
  2. List manifest files
  3. Read and parse YAML manifests
  4. Apply to Kubernetes cluster

  The Executor is stateless and returns a Result struct. The Worker
  handles state updates, events, metrics, and CRD status.

  ## Example

      config = %{url: "...", branch: "main", path: nil, target_namespace: "prod"}
      repo_path = "/tmp/repos/my-app"

      case Executor.execute(config, repo_path) do
        {:ok, result} ->
          # result.commit, result.applied_resources, result.duration_ms
        {:error, reason} ->
          # Handle error
      end
  """

  require Logger

  alias Nopea.Applier
  alias Nopea.Sync.Result

  @type config :: %{
          url: String.t(),
          branch: String.t(),
          path: String.t() | nil,
          target_namespace: String.t() | nil
        }

  @type execute_opts :: [
          git_module: module(),
          k8s_module: module()
        ]

  @doc """
  Executes the sync cycle for a repository.

  ## Parameters

  - `config` - Repository configuration with url, branch, path, target_namespace
  - `repo_path` - Local filesystem path for the repository
  - `opts` - Optional modules for dependency injection (testing)

  ## Returns

  - `{:ok, Result.t()}` - Sync succeeded with commit, resources, and timing
  - `{:error, reason}` - Sync failed with error details

  ## Error Reasons

  - `{:git_sync_failed, reason}` - Git clone/fetch failed
  - `{:list_files_failed, reason}` - Could not list YAML files
  - `{:parse_failed, errors}` - YAML parsing errors
  - `{:apply_failed, errors}` - Kubernetes apply errors
  """
  @spec execute(config(), String.t(), execute_opts()) ::
          {:ok, Result.t()} | {:error, term()}
  def execute(config, repo_path, opts \\ []) do
    git_module = Keyword.get(opts, :git_module, Nopea.Git)
    k8s_module = Keyword.get(opts, :k8s_module, Nopea.K8s)

    start_time = System.monotonic_time(:millisecond)

    with {:ok, commit_sha} <- git_sync(git_module, config, repo_path),
         {:ok, files} <- list_files(git_module, repo_path, config.path),
         {:ok, manifests} <- read_and_parse(git_module, repo_path, config.path, files),
         {:ok, applied_resources} <-
           apply_manifests(k8s_module, manifests, config.target_namespace) do
      duration_ms = System.monotonic_time(:millisecond) - start_time

      {:ok, Result.new(commit_sha, applied_resources, duration_ms)}
    end
  end

  # Git sync: clone if not exists, fetch+reset if exists
  defp git_sync(git_module, config, repo_path) do
    case git_module.sync(config.url, config.branch, repo_path) do
      {:ok, commit_sha} -> {:ok, commit_sha}
      {:error, reason} -> {:error, {:git_sync_failed, reason}}
    end
  end

  # List YAML/YML files in repository
  defp list_files(git_module, repo_path, subpath) do
    case git_module.files(repo_path, subpath) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, {:list_files_failed, reason}}
    end
  end

  # Read and parse all manifest files
  defp read_and_parse(git_module, repo_path, subpath, files) do
    results =
      Enum.map(files, fn file ->
        file_path = if subpath, do: Path.join(subpath, file), else: file
        read_and_parse_file(git_module, repo_path, file_path, file)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      manifests = Enum.flat_map(results, fn {:ok, m} -> m end)
      {:ok, manifests}
    else
      {:error, {:parse_failed, errors}}
    end
  end

  defp read_and_parse_file(git_module, repo_path, file_path, original_file) do
    with {:ok, base64_content} <- git_module.read(repo_path, file_path),
         {:ok, content} <- git_module.decode_content(base64_content),
         {:ok, manifests} <- Applier.parse_manifests(content) do
      {:ok, manifests}
    else
      {:error, reason} -> {:error, {original_file, reason}}
    end
  end

  # Apply manifests to Kubernetes
  defp apply_manifests(k8s_module, manifests, target_namespace) do
    k8s_module.apply_manifests(manifests, target_namespace)
  end
end
