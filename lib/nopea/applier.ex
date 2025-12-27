defmodule Nopea.Applier do
  @moduledoc """
  Handles parsing and applying K8s manifests.

  Responsibilities:
  - Parse YAML manifests (single and multi-document)
  - Validate manifest structure
  - Compute content hashes for drift detection
  - Apply manifests to K8s cluster
  """

  require Logger

  @doc """
  Parses YAML content into a list of manifests.
  Handles multi-document YAML (separated by ---).
  """
  @spec parse_manifests(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_manifests(yaml_content) do
    case YamlElixir.read_all_from_string(yaml_content) do
      {:ok, documents} ->
        # Filter out empty documents and those without required fields
        manifests =
          documents
          |> Enum.reject(fn doc -> is_nil(doc) or map_size(doc) == 0 end)
          |> Enum.filter(&has_required_fields?/1)

        {:ok, manifests}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates a unique key for a resource.
  Format: Kind/Namespace/Name
  """
  @spec resource_key(map()) :: String.t()
  def resource_key(manifest) do
    kind = Map.get(manifest, "kind", "Unknown")
    metadata = Map.get(manifest, "metadata", %{})
    name = Map.get(metadata, "name", "unnamed")
    namespace = Map.get(metadata, "namespace", "default")

    "#{kind}/#{namespace}/#{name}"
  end

  @doc """
  Computes a SHA256 hash of a manifest for drift detection.
  """
  @spec compute_hash(map()) :: {:ok, String.t()} | {:error, term()}
  def compute_hash(manifest) do
    case Jason.encode(manifest, pretty: false) do
      {:ok, json} ->
        hash = :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
        {:ok, "sha256:#{hash}"}

      {:error, reason} ->
        Logger.error("Failed to encode manifest for hashing: #{inspect(reason)}")
        {:error, {:encode_error, reason}}
    end
  end

  @doc """
  Validates that a manifest has required fields.
  """
  @spec validate_manifest(map()) :: :ok | {:error, atom()}
  def validate_manifest(manifest) do
    cond do
      not Map.has_key?(manifest, "apiVersion") ->
        {:error, :missing_api_version}

      not Map.has_key?(manifest, "kind") ->
        {:error, :missing_kind}

      not Map.has_key?(manifest, "metadata") ->
        {:error, :missing_metadata}

      not Map.has_key?(Map.get(manifest, "metadata", %{}), "name") ->
        {:error, :missing_name}

      true ->
        :ok
    end
  end

  @doc """
  Applies a list of manifests to the K8s cluster.
  Returns {:ok, count} on success or {:error, reason} on failure.
  """
  @spec apply_manifests([map()], K8s.Conn.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def apply_manifests(manifests, conn, target_namespace) do
    Logger.info("Applying #{length(manifests)} manifests to namespace: #{target_namespace}")

    results =
      manifests
      |> Enum.map(fn manifest ->
        apply_single(manifest, conn, target_namespace)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, length(manifests)}
    else
      {:error, {:apply_failed, errors}}
    end
  end

  @doc """
  Applies a single manifest to the cluster using server-side apply.
  """
  @spec apply_single(map(), K8s.Conn.t(), String.t()) :: :ok | {:error, term()}
  def apply_single(manifest, conn, target_namespace) do
    # Validate first
    with :ok <- validate_manifest(manifest) do
      # Override namespace if target specified
      manifest =
        if target_namespace do
          put_in(manifest, ["metadata", "namespace"], target_namespace)
        else
          manifest
        end

      key = resource_key(manifest)
      Logger.debug("Applying resource: #{key}")

      # Use server-side apply (K8s 1.18+)
      operation = K8s.Client.apply(manifest, field_manager: "nopea", force: true)

      case K8s.Client.run(conn, operation) do
        {:ok, _result} ->
          Logger.info("Applied: #{key}")
          :ok

        {:error, reason} = error ->
          Logger.error("Failed to apply #{key}: #{inspect(reason)}")
          error
      end
    end
  end

  @doc """
  Reads all YAML files from a directory.
  """
  @spec read_manifests_from_path(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_manifests_from_path(path) do
    Logger.debug("Reading manifests from: #{path}")

    yaml_files =
      Path.join(path, "**/*.{yaml,yml}")
      |> Path.wildcard()
      |> Enum.sort()

    if Enum.empty?(yaml_files) do
      Logger.warning("No YAML files found in: #{path}")
      {:ok, []}
    else
      collect_manifests(yaml_files)
    end
  end

  defp collect_manifests(yaml_files) do
    results = Enum.map(yaml_files, &read_yaml_file/1)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      manifests = Enum.flat_map(results, fn {:ok, {_file, manifests}} -> manifests end)
      {:ok, manifests}
    else
      {:error, {:parse_failed, errors}}
    end
  end

  defp read_yaml_file(file) do
    with {:ok, content} <- File.read(file),
         {:ok, manifests} <- parse_manifests(content) do
      {:ok, {file, manifests}}
    else
      {:error, reason} -> {:error, {file, reason}}
    end
  end

  # Check if a manifest has required K8s fields
  defp has_required_fields?(manifest) when is_map(manifest) do
    Map.has_key?(manifest, "apiVersion") and
      Map.has_key?(manifest, "kind") and
      Map.has_key?(manifest, "metadata") and
      is_map(Map.get(manifest, "metadata")) and
      Map.has_key?(Map.get(manifest, "metadata"), "name")
  end

  defp has_required_fields?(_), do: false
end
