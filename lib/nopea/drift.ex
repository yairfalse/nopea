defmodule Nopea.Drift do
  @moduledoc """
  Three-way drift detection for GitOps reconciliation.

  Compares three states to detect drift:
  - **Last Applied**: What we last applied to the cluster
  - **Desired**: What's currently in git (desired state)
  - **Live**: What's actually in the K8s cluster

  This enables detecting both:
  - Git changes (desired ≠ last_applied)
  - Manual drift (live ≠ last_applied)

  ## Example

      case Drift.three_way_diff(last_applied, desired, live) do
        :no_drift -> :ok
        {:git_change, diff} -> apply_and_update_cache(desired)
        {:manual_drift, diff} -> heal_drift(desired)
        {:conflict, diff} -> resolve_conflict(desired, live)
      end
  """

  require Logger

  @type diff_result ::
          :no_drift
          | {:git_change, map()}
          | {:manual_drift, map()}
          | {:conflict, map()}

  # Fields that K8s adds automatically and should be ignored in comparisons
  @k8s_managed_metadata_fields [
    "resourceVersion",
    "uid",
    "creationTimestamp",
    "generation",
    "managedFields",
    "selfLink"
  ]

  # Annotations that should be stripped
  @k8s_managed_annotations [
    "kubectl.kubernetes.io/last-applied-configuration"
  ]

  @doc """
  Normalizes a manifest by removing K8s-managed fields.

  Strips:
  - `metadata.resourceVersion`, `uid`, `creationTimestamp`, `generation`, `managedFields`
  - `status` section entirely
  - `kubectl.kubernetes.io/last-applied-configuration` annotation

  This allows comparing manifests from different sources (git vs cluster)
  without false positives from K8s-added fields.
  """
  @spec normalize(map()) :: map()
  def normalize(manifest) when is_map(manifest) do
    manifest
    |> strip_status()
    |> strip_managed_metadata()
    |> strip_managed_annotations()
  end

  @doc """
  Performs three-way diff to detect drift type.

  ## Parameters

  - `last_applied` - The manifest we last applied to the cluster
  - `desired` - The current desired state from git
  - `live` - The current state in the K8s cluster

  ## Returns

  - `:no_drift` - All three states match (normalized)
  - `{:git_change, diff}` - Git has changed, cluster matches last applied
  - `{:manual_drift, diff}` - Cluster changed manually, git matches last applied
  - `{:conflict, diff}` - Both git and cluster have diverged from last applied
  """
  @spec three_way_diff(map(), map(), map()) :: diff_result()
  def three_way_diff(last_applied, desired, live) do
    # Normalize all three for comparison
    norm_last = normalize(last_applied)
    norm_desired = normalize(desired)
    norm_live = normalize(live)

    # Compute hashes for comparison
    last_hash = do_hash(norm_last)
    desired_hash = do_hash(norm_desired)
    live_hash = do_hash(norm_live)

    git_changed = desired_hash != last_hash
    manual_drift = live_hash != last_hash

    cond do
      not git_changed and not manual_drift ->
        :no_drift

      git_changed and not manual_drift ->
        {:git_change, %{from: last_hash, to: desired_hash}}

      not git_changed and manual_drift ->
        {:manual_drift, %{expected: last_hash, actual: live_hash}}

      git_changed and manual_drift ->
        {:conflict, %{last: last_hash, desired: desired_hash, live: live_hash}}
    end
  end

  @doc """
  Checks if the desired state (from git) differs from the last-applied state.

  This is a simplified two-way comparison for detecting git changes when
  cluster state is not available. For full three-way drift detection
  (including manual drift), use `three_way_diff/3`.

  ## Returns

  - `false` - No changes (git matches last-applied)
  - `{:changed, diff}` - Git has changed since last apply
  """
  @spec git_changed?(map(), map()) :: false | {:changed, map()}
  def git_changed?(last_applied, desired) do
    norm_last = normalize(last_applied)
    norm_desired = normalize(desired)

    last_hash = do_hash(norm_last)
    desired_hash = do_hash(norm_desired)

    if last_hash == desired_hash do
      false
    else
      {:changed, %{from: last_hash, to: desired_hash}}
    end
  end

  @doc """
  Computes a normalized hash of a manifest for drift detection.

  The manifest is normalized before hashing, so K8s-added fields
  don't affect the hash.
  """
  @spec compute_hash(map()) :: {:ok, String.t()} | {:error, term()}
  def compute_hash(manifest) do
    normalized = normalize(manifest)
    {:ok, "sha256:#{do_hash(normalized)}"}
  end

  # Private functions

  defp strip_status(manifest) do
    Map.delete(manifest, "status")
  end

  defp strip_managed_metadata(manifest) do
    case Map.get(manifest, "metadata") do
      nil ->
        manifest

      metadata ->
        cleaned_metadata = Map.drop(metadata, @k8s_managed_metadata_fields)
        Map.put(manifest, "metadata", cleaned_metadata)
    end
  end

  defp strip_managed_annotations(manifest) do
    case get_in(manifest, ["metadata", "annotations"]) do
      nil ->
        manifest

      annotations ->
        cleaned_annotations = Map.drop(annotations, @k8s_managed_annotations)

        # Remove annotations key entirely if empty
        if map_size(cleaned_annotations) == 0 do
          update_in(manifest, ["metadata"], &Map.delete(&1, "annotations"))
        else
          put_in(manifest, ["metadata", "annotations"], cleaned_annotations)
        end
    end
  end

  # Core hashing implementation - encodes to JSON and hashes with SHA256
  defp do_hash(normalized_manifest) do
    # JSON encoding should always succeed for valid K8s manifests
    # If it fails, we fall back to inspect() for safety
    json =
      case Jason.encode(normalized_manifest, pretty: false) do
        {:ok, encoded} -> encoded
        {:error, _} -> inspect(normalized_manifest)
      end

    :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
  end
end
