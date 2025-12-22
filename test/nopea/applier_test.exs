defmodule Nopea.ApplierTest do
  use ExUnit.Case, async: true

  alias Nopea.Applier

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

      {:ok, hash1} = Applier.compute_hash(manifest)
      {:ok, hash2} = Applier.compute_hash(manifest)

      assert hash1 == hash2
      assert String.starts_with?(hash1, "sha256:")
    end

    test "produces different hashes for different manifests" do
      manifest1 = %{"kind" => "ConfigMap", "data" => %{"key" => "value1"}}
      manifest2 = %{"kind" => "ConfigMap", "data" => %{"key" => "value2"}}

      {:ok, hash1} = Applier.compute_hash(manifest1)
      {:ok, hash2} = Applier.compute_hash(manifest2)

      assert hash1 != hash2
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

    test "returns error for missing metadata entirely" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap"
      }

      assert {:error, :missing_metadata} = Applier.validate_manifest(manifest)
    end
  end

  describe "read_manifests_from_path/1" do
    setup do
      # Create a temp directory for test files
      tmp_dir =
        Path.join(System.tmp_dir!(), "nopea_applier_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "reads single YAML file", %{tmp_dir: tmp_dir} do
      yaml = """
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: test-config
      data:
        key: value
      """

      File.write!(Path.join(tmp_dir, "config.yaml"), yaml)

      assert {:ok, [manifest]} = Applier.read_manifests_from_path(tmp_dir)
      assert manifest["kind"] == "ConfigMap"
      assert manifest["metadata"]["name"] == "test-config"
    end

    test "reads multiple YAML files sorted alphabetically", %{tmp_dir: tmp_dir} do
      yaml1 = """
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: b-config
      """

      yaml2 = """
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: a-config
      """

      File.write!(Path.join(tmp_dir, "02-second.yaml"), yaml1)
      File.write!(Path.join(tmp_dir, "01-first.yaml"), yaml2)

      assert {:ok, manifests} = Applier.read_manifests_from_path(tmp_dir)
      assert length(manifests) == 2
      # Should be sorted alphabetically by filename
      assert Enum.at(manifests, 0)["metadata"]["name"] == "a-config"
      assert Enum.at(manifests, 1)["metadata"]["name"] == "b-config"
    end

    test "reads multi-document YAML files", %{tmp_dir: tmp_dir} do
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

      File.write!(Path.join(tmp_dir, "multi.yaml"), yaml)

      assert {:ok, manifests} = Applier.read_manifests_from_path(tmp_dir)
      assert length(manifests) == 2
      assert Enum.at(manifests, 0)["metadata"]["name"] == "config-1"
      assert Enum.at(manifests, 1)["metadata"]["name"] == "config-2"
    end

    test "reads .yml extension files", %{tmp_dir: tmp_dir} do
      yaml = """
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: yml-config
      """

      File.write!(Path.join(tmp_dir, "config.yml"), yaml)

      assert {:ok, [manifest]} = Applier.read_manifests_from_path(tmp_dir)
      assert manifest["metadata"]["name"] == "yml-config"
    end

    test "reads from nested directories", %{tmp_dir: tmp_dir} do
      nested_dir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(nested_dir)

      yaml = """
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: nested-config
      """

      File.write!(Path.join(nested_dir, "config.yaml"), yaml)

      assert {:ok, [manifest]} = Applier.read_manifests_from_path(tmp_dir)
      assert manifest["metadata"]["name"] == "nested-config"
    end

    test "returns empty list for directory with no YAML files", %{tmp_dir: tmp_dir} do
      # Create a non-YAML file
      File.write!(Path.join(tmp_dir, "readme.txt"), "not yaml")

      assert {:ok, []} = Applier.read_manifests_from_path(tmp_dir)
    end

    test "returns error for invalid YAML file", %{tmp_dir: tmp_dir} do
      invalid_yaml = """
      invalid: yaml: [
      """

      File.write!(Path.join(tmp_dir, "bad.yaml"), invalid_yaml)

      assert {:error, {:parse_failed, _errors}} = Applier.read_manifests_from_path(tmp_dir)
    end
  end
end
