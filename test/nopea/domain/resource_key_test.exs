defmodule Nopea.Domain.ResourceKeyTest do
  use ExUnit.Case, async: true

  alias Nopea.Domain.ResourceKey

  describe "new/3" do
    test "creates a resource key with valid inputs" do
      key = ResourceKey.new("Deployment", "production", "api")

      assert key.kind == "Deployment"
      assert key.namespace == "production"
      assert key.name == "api"
    end

    test "creates resource key with default namespace" do
      key = ResourceKey.new("ConfigMap", "default", "config")

      assert key.namespace == "default"
    end
  end

  describe "parse/1" do
    test "parses valid resource key string" do
      assert {:ok, key} = ResourceKey.parse("Deployment/production/api")

      assert key.kind == "Deployment"
      assert key.namespace == "production"
      assert key.name == "api"
    end

    test "parses resource key with multi-segment name" do
      assert {:ok, key} = ResourceKey.parse("Service/default/my-app-service")

      assert key.kind == "Service"
      assert key.namespace == "default"
      assert key.name == "my-app-service"
    end

    test "returns error for invalid format - missing parts" do
      assert {:error, :invalid_format} = ResourceKey.parse("Deployment/api")
      assert {:error, :invalid_format} = ResourceKey.parse("Deployment")
      assert {:error, :invalid_format} = ResourceKey.parse("")
    end

    test "returns error for empty segments" do
      assert {:error, :invalid_format} = ResourceKey.parse("//name")
      assert {:error, :invalid_format} = ResourceKey.parse("Kind//name")
      assert {:error, :invalid_format} = ResourceKey.parse("Kind/ns/")
    end
  end

  describe "to_string/1" do
    test "formats resource key as Kind/Namespace/Name" do
      key = ResourceKey.new("Deployment", "production", "api")

      assert ResourceKey.to_string(key) == "Deployment/production/api"
    end

    test "roundtrips through parse and to_string" do
      original = "ConfigMap/kube-system/coredns"

      {:ok, key} = ResourceKey.parse(original)
      result = ResourceKey.to_string(key)

      assert result == original
    end
  end

  describe "from_manifest/1" do
    test "extracts resource key from K8s manifest" do
      manifest = %{
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => %{
          "name" => "api",
          "namespace" => "production"
        }
      }

      assert {:ok, key} = ResourceKey.from_manifest(manifest)
      assert key.kind == "Deployment"
      assert key.namespace == "production"
      assert key.name == "api"
    end

    test "uses default namespace when not specified" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "config"
        }
      }

      assert {:ok, key} = ResourceKey.from_manifest(manifest)
      assert key.namespace == "default"
    end

    test "returns error when kind is missing" do
      manifest = %{
        "metadata" => %{"name" => "api"}
      }

      assert {:error, :missing_kind} = ResourceKey.from_manifest(manifest)
    end

    test "returns error when name is missing" do
      manifest = %{
        "kind" => "Deployment",
        "metadata" => %{}
      }

      assert {:error, :missing_name} = ResourceKey.from_manifest(manifest)
    end

    test "returns error when metadata is missing" do
      manifest = %{
        "kind" => "Deployment"
      }

      assert {:error, :missing_metadata} = ResourceKey.from_manifest(manifest)
    end
  end

  describe "String.Chars protocol" do
    test "allows interpolation in strings" do
      key = ResourceKey.new("Deployment", "prod", "api")

      assert "Resource: #{key}" == "Resource: Deployment/prod/api"
    end
  end

  describe "equality" do
    test "two keys with same values are equal" do
      key1 = ResourceKey.new("Deployment", "prod", "api")
      key2 = ResourceKey.new("Deployment", "prod", "api")

      assert key1 == key2
    end

    test "two keys with different values are not equal" do
      key1 = ResourceKey.new("Deployment", "prod", "api")
      key2 = ResourceKey.new("Deployment", "staging", "api")

      refute key1 == key2
    end
  end
end
