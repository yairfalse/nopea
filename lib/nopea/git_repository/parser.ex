defmodule Nopea.GitRepository.Parser do
  @moduledoc """
  Shared parsing utilities for GitRepository CRD resources.

  Provides functions to parse interval strings and heal policy values
  from Kubernetes CRD specs. Used by both Controller and Worker modules.
  """

  @doc """
  Parses a duration string like "5m", "1h", "30s" into milliseconds.

  ## Examples

      iex> Nopea.GitRepository.Parser.parse_interval("5m")
      300_000

      iex> Nopea.GitRepository.Parser.parse_interval("30s")
      30_000

      iex> Nopea.GitRepository.Parser.parse_interval("1h")
      3_600_000

      iex> Nopea.GitRepository.Parser.parse_interval(nil)
      nil
  """
  @spec parse_interval(String.t() | integer() | nil) :: integer() | nil
  def parse_interval(interval) when is_binary(interval) do
    case Regex.run(~r/^(\d+)(s|m|h)$/, interval) do
      [_, num, "s"] -> String.to_integer(num) * 1_000
      [_, num, "m"] -> String.to_integer(num) * 60 * 1_000
      [_, num, "h"] -> String.to_integer(num) * 60 * 60 * 1_000
      # Default 5 minutes
      _ -> 5 * 60 * 1_000
    end
  end

  def parse_interval(interval) when is_integer(interval), do: interval * 1_000
  def parse_interval(nil), do: nil
  def parse_interval(_), do: 5 * 60 * 1_000

  @doc """
  Parses a heal policy string into an atom.

  ## Examples

      iex> Nopea.GitRepository.Parser.parse_heal_policy("auto")
      :auto

      iex> Nopea.GitRepository.Parser.parse_heal_policy("manual")
      :manual

      iex> Nopea.GitRepository.Parser.parse_heal_policy("notify")
      :notify

      iex> Nopea.GitRepository.Parser.parse_heal_policy("invalid")
      :auto
  """
  @spec parse_heal_policy(String.t() | nil) :: :auto | :manual | :notify
  def parse_heal_policy("auto"), do: :auto
  def parse_heal_policy("manual"), do: :manual
  def parse_heal_policy("notify"), do: :notify
  def parse_heal_policy(_), do: :auto

  @doc """
  Builds a worker config map from a GitRepository CRD resource.

  Validates required fields and raises ArgumentError if missing.

  ## Required fields
  - `metadata.name`
  - `metadata.namespace`
  - `spec.url`
  """
  @spec build_config(map()) :: map()
  def build_config(resource) do
    name = get_in(resource, ["metadata", "name"])
    namespace = get_in(resource, ["metadata", "namespace"])
    spec = Map.get(resource, "spec", %{})
    url = Map.get(spec, "url")

    validate_required!(name, namespace, url)

    %{
      name: name,
      namespace: namespace,
      url: url,
      branch: Map.get(spec, "branch", "main"),
      path: Map.get(spec, "path"),
      target_namespace: Map.get(spec, "targetNamespace", namespace),
      interval: parse_interval(Map.get(spec, "interval", "5m")),
      suspend: Map.get(spec, "suspend", false),
      heal_policy: parse_heal_policy(Map.get(spec, "healPolicy", "auto")),
      heal_grace_period: parse_interval(Map.get(spec, "healGracePeriod"))
    }
  end

  defp validate_required!(name, namespace, url) do
    cond do
      is_nil(name) or name == "" ->
        raise ArgumentError, "GitRepository resource is missing required metadata.name"

      is_nil(namespace) or namespace == "" ->
        raise ArgumentError,
              "GitRepository resource #{inspect(name)} is missing required metadata.namespace"

      is_nil(url) or url == "" ->
        raise ArgumentError,
              "GitRepository resource #{inspect(namespace)}/#{inspect(name)} is missing required spec.url"

      true ->
        :ok
    end
  end
end
