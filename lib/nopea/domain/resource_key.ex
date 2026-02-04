defmodule Nopea.Domain.ResourceKey do
  @moduledoc """
  Value object representing a Kubernetes resource identifier.

  A resource key uniquely identifies a K8s resource using the format:
  `Kind/Namespace/Name` (e.g., "Deployment/production/api").

  ## Why a Value Object?

  Resource keys are passed through many modules (Applier, Cache, Drift,
  Worker, Events). Using a struct instead of a raw string provides:

  - Type safety: Compiler catches misuse
  - Validation: Invalid keys rejected at creation
  - Self-documenting: Fields are explicit
  - Behavior: Methods like `to_string/1`, `from_manifest/1`

  ## Examples

      iex> key = ResourceKey.new("Deployment", "prod", "api")
      iex> ResourceKey.to_string(key)
      "Deployment/prod/api"

      iex> {:ok, key} = ResourceKey.parse("Service/default/web")
      iex> key.kind
      "Service"

      iex> {:ok, key} = ResourceKey.from_manifest(%{
      ...>   "kind" => "ConfigMap",
      ...>   "metadata" => %{"name" => "config", "namespace" => "prod"}
      ...> })
      iex> key.name
      "config"
  """

  @enforce_keys [:kind, :namespace, :name]
  defstruct [:kind, :namespace, :name]

  @type t :: %__MODULE__{
          kind: String.t(),
          namespace: String.t(),
          name: String.t()
        }

  @doc """
  Creates a new resource key.

  ## Parameters

  - `kind` - K8s resource kind (e.g., "Deployment", "Service")
  - `namespace` - K8s namespace
  - `name` - Resource name

  ## Examples

      iex> ResourceKey.new("Deployment", "production", "api")
      %ResourceKey{kind: "Deployment", namespace: "production", name: "api"}
  """
  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(kind, namespace, name) do
    %__MODULE__{
      kind: kind,
      namespace: namespace,
      name: name
    }
  end

  @doc """
  Parses a resource key string into a struct.

  Expected format: `Kind/Namespace/Name`

  ## Examples

      iex> ResourceKey.parse("Deployment/prod/api")
      {:ok, %ResourceKey{kind: "Deployment", namespace: "prod", name: "api"}}

      iex> ResourceKey.parse("invalid")
      {:error, :invalid_format}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(string) when is_binary(string) do
    case String.split(string, "/", parts: 3) do
      [kind, namespace, name] when kind != "" and namespace != "" and name != "" ->
        {:ok, new(kind, namespace, name)}

      _ ->
        {:error, :invalid_format}
    end
  end

  @doc """
  Converts a resource key to its string representation.

  ## Examples

      iex> key = ResourceKey.new("Deployment", "prod", "api")
      iex> ResourceKey.to_string(key)
      "Deployment/prod/api"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{kind: kind, namespace: namespace, name: name}) do
    "#{kind}/#{namespace}/#{name}"
  end

  @doc """
  Extracts a resource key from a K8s manifest.

  ## Parameters

  - `manifest` - Map with "kind" and "metadata" (containing "name", optionally "namespace")

  ## Returns

  - `{:ok, resource_key}` on success
  - `{:error, :missing_kind}` if kind is missing
  - `{:error, :missing_metadata}` if metadata is missing
  - `{:error, :missing_name}` if name is missing from metadata

  ## Examples

      iex> manifest = %{
      ...>   "kind" => "Deployment",
      ...>   "metadata" => %{"name" => "api", "namespace" => "prod"}
      ...> }
      iex> ResourceKey.from_manifest(manifest)
      {:ok, %ResourceKey{kind: "Deployment", namespace: "prod", name: "api"}}
  """
  @spec from_manifest(map()) ::
          {:ok, t()}
          | {:error, :missing_kind}
          | {:error, :missing_metadata}
          | {:error, :missing_name}
  def from_manifest(manifest) when is_map(manifest) do
    with {:ok, kind} <- fetch_kind(manifest),
         {:ok, metadata} <- fetch_metadata(manifest),
         {:ok, name} <- fetch_name(metadata) do
      namespace = Map.get(metadata, "namespace", "default")
      {:ok, new(kind, namespace, name)}
    end
  end

  defp fetch_kind(manifest) do
    case Map.fetch(manifest, "kind") do
      {:ok, kind} when is_binary(kind) -> {:ok, kind}
      _ -> {:error, :missing_kind}
    end
  end

  defp fetch_metadata(manifest) do
    case Map.fetch(manifest, "metadata") do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      _ -> {:error, :missing_metadata}
    end
  end

  defp fetch_name(metadata) do
    case Map.fetch(metadata, "name") do
      {:ok, name} when is_binary(name) -> {:ok, name}
      _ -> {:error, :missing_name}
    end
  end
end

# Implement String.Chars protocol for string interpolation
defimpl String.Chars, for: Nopea.Domain.ResourceKey do
  alias Nopea.Domain.ResourceKey

  def to_string(key) do
    ResourceKey.to_string(key)
  end
end
