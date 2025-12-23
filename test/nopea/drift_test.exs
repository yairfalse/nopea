defmodule Nopea.DriftTest do
  use ExUnit.Case, async: true

  alias Nopea.Drift

  @moduletag :drift

  describe "normalize/1" do
    test "strips metadata.resourceVersion" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "my-config",
          "namespace" => "default",
          "resourceVersion" => "12345"
        },
        "data" => %{"key" => "value"}
      }

      normalized = Drift.normalize(manifest)

      refute Map.has_key?(normalized["metadata"], "resourceVersion")
      assert normalized["metadata"]["name"] == "my-config"
    end

    test "strips metadata.uid" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "my-config",
          "uid" => "abc-123-def"
        }
      }

      normalized = Drift.normalize(manifest)

      refute Map.has_key?(normalized["metadata"], "uid")
    end

    test "strips metadata.creationTimestamp" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "my-config",
          "creationTimestamp" => "2024-01-01T00:00:00Z"
        }
      }

      normalized = Drift.normalize(manifest)

      refute Map.has_key?(normalized["metadata"], "creationTimestamp")
    end

    test "strips metadata.generation" do
      manifest = %{
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => %{
          "name" => "my-app",
          "generation" => 5
        }
      }

      normalized = Drift.normalize(manifest)

      refute Map.has_key?(normalized["metadata"], "generation")
    end

    test "strips metadata.managedFields" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "my-config",
          "managedFields" => [%{"manager" => "kubectl", "operation" => "Apply"}]
        }
      }

      normalized = Drift.normalize(manifest)

      refute Map.has_key?(normalized["metadata"], "managedFields")
    end

    test "strips status section entirely" do
      manifest = %{
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => %{"name" => "my-app"},
        "spec" => %{"replicas" => 3},
        "status" => %{
          "availableReplicas" => 3,
          "readyReplicas" => 3,
          "conditions" => []
        }
      }

      normalized = Drift.normalize(manifest)

      refute Map.has_key?(normalized, "status")
      assert normalized["spec"]["replicas"] == 3
    end

    test "strips kubectl last-applied-configuration annotation" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "my-config",
          "annotations" => %{
            "kubectl.kubernetes.io/last-applied-configuration" => "{...}",
            "my-annotation" => "keep-me"
          }
        }
      }

      normalized = Drift.normalize(manifest)

      refute Map.has_key?(
               normalized["metadata"]["annotations"],
               "kubectl.kubernetes.io/last-applied-configuration"
             )

      assert normalized["metadata"]["annotations"]["my-annotation"] == "keep-me"
    end

    test "preserves spec and other important fields" do
      manifest = %{
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => %{
          "name" => "my-app",
          "namespace" => "production",
          "labels" => %{"app" => "my-app"},
          "resourceVersion" => "12345"
        },
        "spec" => %{
          "replicas" => 3,
          "selector" => %{"matchLabels" => %{"app" => "my-app"}},
          "template" => %{
            "spec" => %{"containers" => [%{"name" => "app", "image" => "my-app:v1"}]}
          }
        },
        "status" => %{"availableReplicas" => 3}
      }

      normalized = Drift.normalize(manifest)

      assert normalized["apiVersion"] == "apps/v1"
      assert normalized["kind"] == "Deployment"
      assert normalized["metadata"]["name"] == "my-app"
      assert normalized["metadata"]["namespace"] == "production"
      assert normalized["metadata"]["labels"] == %{"app" => "my-app"}
      assert normalized["spec"]["replicas"] == 3
      refute Map.has_key?(normalized, "status")
      refute Map.has_key?(normalized["metadata"], "resourceVersion")
    end
  end

  describe "three_way_diff/3" do
    test "returns :no_drift when all three states match" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "value"}
      }

      result = Drift.three_way_diff(manifest, manifest, manifest)

      assert result == :no_drift
    end

    test "detects git change when desired differs from last_applied" do
      last_applied = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "old-value"}
      }

      desired = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "new-value"}
      }

      # Live matches last_applied (no manual changes)
      live = last_applied

      result = Drift.three_way_diff(last_applied, desired, live)

      assert {:git_change, _diff} = result
    end

    test "detects manual drift when live differs from last_applied" do
      last_applied = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "original"}
      }

      # Desired matches last_applied (no git changes)
      desired = last_applied

      # Someone manually changed it in the cluster
      live = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "manually-changed"}
      }

      result = Drift.three_way_diff(last_applied, desired, live)

      assert {:manual_drift, _diff} = result
    end

    test "detects both git change and manual drift" do
      last_applied = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "original"}
      }

      desired = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "from-git"}
      }

      live = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "manually-changed"}
      }

      result = Drift.three_way_diff(last_applied, desired, live)

      assert {:conflict, _diff} = result
    end

    test "ignores K8s-added fields in live state" do
      last_applied = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "value"}
      }

      desired = last_applied

      # Live has K8s-added fields but same content
      live = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "my-config",
          "resourceVersion" => "12345",
          "uid" => "abc-123",
          "creationTimestamp" => "2024-01-01T00:00:00Z"
        },
        "data" => %{"key" => "value"}
      }

      result = Drift.three_way_diff(last_applied, desired, live)

      assert result == :no_drift
    end
  end

  describe "git_changed?/2" do
    test "returns false when manifests match" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "value"}
      }

      result = Drift.git_changed?(manifest, manifest)

      assert result == false
    end

    test "returns {:changed, diff} when manifests differ" do
      last_applied = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "old-value"}
      }

      desired = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "new-value"}
      }

      result = Drift.git_changed?(last_applied, desired)

      assert {:changed, %{from: from_hash, to: to_hash}} = result
      refute from_hash == to_hash
    end

    test "ignores K8s-managed fields when comparing" do
      last_applied = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "my-config"},
        "data" => %{"key" => "value"}
      }

      # Same content but with K8s-added fields
      desired = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "my-config",
          "resourceVersion" => "12345"
        },
        "data" => %{"key" => "value"}
      }

      result = Drift.git_changed?(last_applied, desired)

      assert result == false
    end
  end

  describe "compute_hash/1" do
    test "returns consistent hash for same content" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "test"},
        "data" => %{"key" => "value"}
      }

      {:ok, hash1} = Drift.compute_hash(manifest)
      {:ok, hash2} = Drift.compute_hash(manifest)

      assert hash1 == hash2
      assert String.starts_with?(hash1, "sha256:")
    end

    test "returns different hash for different content" do
      manifest1 = %{"data" => %{"key" => "value1"}}
      manifest2 = %{"data" => %{"key" => "value2"}}

      {:ok, hash1} = Drift.compute_hash(manifest1)
      {:ok, hash2} = Drift.compute_hash(manifest2)

      refute hash1 == hash2
    end

    test "normalizes before hashing" do
      # Same content but one has K8s-added fields
      manifest1 = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "test"},
        "data" => %{"key" => "value"}
      }

      manifest2 = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "test",
          "resourceVersion" => "12345",
          "uid" => "abc"
        },
        "data" => %{"key" => "value"}
      }

      {:ok, hash1} = Drift.compute_hash(manifest1)
      {:ok, hash2} = Drift.compute_hash(manifest2)

      assert hash1 == hash2
    end
  end
end
