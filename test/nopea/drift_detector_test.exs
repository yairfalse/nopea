defmodule Nopea.DriftDetectorTest do
  @moduledoc """
  Tests for three-way drift detection with cluster state.

  These tests verify that manual drift (changes made directly to the cluster)
  is detected when comparing last_applied, desired (git), and live (cluster) states.
  """

  use ExUnit.Case, async: true

  import Mox

  alias Nopea.{Cache, Drift}

  @moduletag :drift_detector

  setup :verify_on_exit!

  setup do
    start_supervised!(Nopea.Cache)
    :ok
  end

  describe "detect_drift_with_cluster/3" do
    test "returns :no_drift when all states match" do
      manifest = deployment_manifest("my-app", replicas: 3)

      # All three states are identical
      result = Drift.detect_drift_with_cluster(manifest, manifest, manifest)

      assert result == :no_drift
    end

    test "detects git_change when desired differs from last_applied" do
      last_applied = deployment_manifest("my-app", replicas: 3)
      desired = deployment_manifest("my-app", replicas: 5)
      live = deployment_manifest("my-app", replicas: 3)

      result = Drift.detect_drift_with_cluster(last_applied, desired, live)

      assert {:git_change, _diff} = result
    end

    test "detects manual_drift when live differs from last_applied" do
      last_applied = deployment_manifest("my-app", replicas: 3)
      desired = deployment_manifest("my-app", replicas: 3)
      # Someone kubectl scaled to 5 replicas
      live = deployment_manifest("my-app", replicas: 5)

      result = Drift.detect_drift_with_cluster(last_applied, desired, live)

      assert {:manual_drift, _diff} = result
    end

    test "detects conflict when both git and cluster changed" do
      last_applied = deployment_manifest("my-app", replicas: 3)
      # Git changed to 5
      desired = deployment_manifest("my-app", replicas: 5)
      # Someone kubectl scaled to 10
      live = deployment_manifest("my-app", replicas: 10)

      result = Drift.detect_drift_with_cluster(last_applied, desired, live)

      assert {:conflict, _diff} = result
    end

    test "ignores K8s-managed fields in live state" do
      last_applied = deployment_manifest("my-app", replicas: 3)
      desired = deployment_manifest("my-app", replicas: 3)

      # Live has K8s-added fields but same spec
      live =
        deployment_manifest("my-app", replicas: 3)
        |> put_in(["metadata", "resourceVersion"], "12345")
        |> put_in(["metadata", "uid"], "abc-123-def")
        |> Map.put("status", %{"availableReplicas" => 3})

      result = Drift.detect_drift_with_cluster(last_applied, desired, live)

      assert result == :no_drift
    end
  end

  describe "check_manifest_drift/3 with K8s GET" do
    test "fetches live state from cluster and detects manual drift" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      resource_key = "Deployment/default/my-app"

      # Set up last_applied in cache
      last_applied = deployment_manifest("my-app", replicas: 3)
      Cache.put_last_applied(repo_name, resource_key, Drift.normalize(last_applied))

      # Desired is same as last_applied (no git change)
      desired = deployment_manifest("my-app", replicas: 3)

      # Mock K8s to return live state with manual change
      live =
        deployment_manifest("my-app", replicas: 5)
        |> put_in(["metadata", "resourceVersion"], "99999")

      Nopea.K8sMock
      |> expect(:get_resource, fn "apps/v1", "Deployment", "my-app", "default" ->
        {:ok, live}
      end)

      # This function should exist and use K8s GET
      result = Drift.check_manifest_drift(repo_name, desired, k8s_module: Nopea.K8sMock)

      assert {:manual_drift, _diff} = result
    end

    test "returns :new_resource when not in cache" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      desired = deployment_manifest("my-app", replicas: 3)

      # No last_applied in cache, K8s returns not found
      Nopea.K8sMock
      |> expect(:get_resource, fn "apps/v1", "Deployment", "my-app", "default" ->
        {:error, :not_found}
      end)

      result = Drift.check_manifest_drift(repo_name, desired, k8s_module: Nopea.K8sMock)

      assert result == :new_resource
    end

    test "returns :needs_apply when in cluster but not in cache" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      desired = deployment_manifest("my-app", replicas: 3)

      # Not in cache, but exists in cluster
      live = deployment_manifest("my-app", replicas: 3)

      Nopea.K8sMock
      |> expect(:get_resource, fn "apps/v1", "Deployment", "my-app", "default" ->
        {:ok, live}
      end)

      result = Drift.check_manifest_drift(repo_name, desired, k8s_module: Nopea.K8sMock)

      # Resource exists in cluster but we don't have last_applied
      # Treat as needing apply to establish baseline
      assert result == :needs_apply
    end
  end

  # Helper to create a Deployment manifest
  defp deployment_manifest(name, opts) do
    replicas = Keyword.get(opts, :replicas, 1)

    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => name,
        "namespace" => "default"
      },
      "spec" => %{
        "replicas" => replicas,
        "selector" => %{
          "matchLabels" => %{"app" => name}
        },
        "template" => %{
          "metadata" => %{"labels" => %{"app" => name}},
          "spec" => %{
            "containers" => [
              %{"name" => name, "image" => "#{name}:latest"}
            ]
          }
        }
      }
    }
  end
end
