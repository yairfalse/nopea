defmodule Alumiini.ApplierTest do
  use ExUnit.Case, async: true

  alias Alumiini.Applier

  describe "parse_manifests/1" do
    test "parses single YAML document" do
      yaml = """
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: my-config
        namespace: default
      data:
        key: value
      """

      assert {:ok, [manifest]} = Applier.parse_manifests(yaml)
      assert manifest["apiVersion"] == "v1"
      assert manifest["kind"] == "ConfigMap"
      assert manifest["metadata"]["name"] == "my-config"
    end

    test "parses multi-document YAML" do
      yaml = """
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: config-1
      ---
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: config-2
      """

      assert {:ok, manifests} = Applier.parse_manifests(yaml)
      assert length(manifests) == 2
      assert Enum.at(manifests, 0)["metadata"]["name"] == "config-1"
      assert Enum.at(manifests, 1)["metadata"]["name"] == "config-2"
    end

    test "returns error for invalid YAML" do
      yaml = """
      invalid: yaml: content: [
      """

      assert {:error, _reason} = Applier.parse_manifests(yaml)
    end

    test "skips empty documents" do
      yaml = """
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: config
      ---
      ---
      """

      assert {:ok, [manifest]} = Applier.parse_manifests(yaml)
      assert manifest["metadata"]["name"] == "config"
    end
  end

  describe "resource_key/1" do
    test "generates key from manifest" do
      manifest = %{
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => %{
          "name" => "my-app",
          "namespace" => "production"
        }
      }

      assert Applier.resource_key(manifest) == "Deployment/production/my-app"
    end

    test "uses default namespace when not specified" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "my-config"
        }
      }

      assert Applier.resource_key(manifest) == "ConfigMap/default/my-config"
    end
  end

  describe "compute_hash/1" do
    test "computes consistent hash for manifest" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "test"},
        "data" => %{"key" => "value"}
      }

      hash1 = Applier.compute_hash(manifest)
      hash2 = Applier.compute_hash(manifest)

      assert hash1 == hash2
      assert String.starts_with?(hash1, "sha256:")
    end

    test "produces different hashes for different manifests" do
      manifest1 = %{"kind" => "ConfigMap", "data" => %{"key" => "value1"}}
      manifest2 = %{"kind" => "ConfigMap", "data" => %{"key" => "value2"}}

      assert Applier.compute_hash(manifest1) != Applier.compute_hash(manifest2)
    end
  end

  describe "validate_manifest/1" do
    test "validates manifest with required fields" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "test"}
      }

      assert :ok = Applier.validate_manifest(manifest)
    end

    test "returns error for missing apiVersion" do
      manifest = %{
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "test"}
      }

      assert {:error, :missing_api_version} = Applier.validate_manifest(manifest)
    end

    test "returns error for missing kind" do
      manifest = %{
        "apiVersion" => "v1",
        "metadata" => %{"name" => "test"}
      }

      assert {:error, :missing_kind} = Applier.validate_manifest(manifest)
    end

    test "returns error for missing metadata.name" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{}
      }

      assert {:error, :missing_name} = Applier.validate_manifest(manifest)
    end
  end
end
