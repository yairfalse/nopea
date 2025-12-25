defmodule Nopea.CacheTest do
  use ExUnit.Case, async: false

  alias Nopea.Cache

  setup do
    start_supervised!(Nopea.Cache)
    :ok
  end

  describe "commits cache" do
    test "stores and retrieves commit for repo" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      commit = "abc123def456"

      :ok = Cache.put_commit(repo_name, commit)
      assert {:ok, ^commit} = Cache.get_commit(repo_name)
    end

    test "returns error for unknown repo" do
      assert {:error, :not_found} = Cache.get_commit("unknown-repo")
    end

    test "updates existing commit" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"

      :ok = Cache.put_commit(repo_name, "commit1")
      :ok = Cache.put_commit(repo_name, "commit2")

      assert {:ok, "commit2"} = Cache.get_commit(repo_name)
    end

    test "deletes commit" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"

      :ok = Cache.put_commit(repo_name, "abc123")
      :ok = Cache.delete_commit(repo_name)

      assert {:error, :not_found} = Cache.get_commit(repo_name)
    end
  end

  describe "resource hash cache" do
    test "stores and retrieves resource hash" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      resource_key = "Deployment/default/my-app"
      hash = "sha256:abcdef123456"

      :ok = Cache.put_resource_hash(repo_name, resource_key, hash)
      assert {:ok, ^hash} = Cache.get_resource_hash(repo_name, resource_key)
    end

    test "returns error for unknown resource" do
      assert {:error, :not_found} = Cache.get_resource_hash("repo", "unknown")
    end

    test "lists all resource hashes for repo" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"

      :ok = Cache.put_resource_hash(repo_name, "Deployment/default/app1", "hash1")
      :ok = Cache.put_resource_hash(repo_name, "Service/default/app1", "hash2")

      hashes = Cache.list_resource_hashes(repo_name)
      assert length(hashes) == 2
      assert {"Deployment/default/app1", "hash1"} in hashes
      assert {"Service/default/app1", "hash2"} in hashes
    end

    test "clears all resource hashes for repo" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"

      :ok = Cache.put_resource_hash(repo_name, "Deployment/default/app", "hash1")
      :ok = Cache.clear_resource_hashes(repo_name)

      assert Cache.list_resource_hashes(repo_name) == []
    end
  end

  describe "sync state cache" do
    test "stores and retrieves sync state" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"

      state = %{
        last_sync: DateTime.utc_now(),
        status: :synced,
        resources_applied: 5
      }

      :ok = Cache.put_sync_state(repo_name, state)
      assert {:ok, retrieved} = Cache.get_sync_state(repo_name)
      assert retrieved.status == :synced
      assert retrieved.resources_applied == 5
    end

    test "returns error for unknown repo sync state" do
      assert {:error, :not_found} = Cache.get_sync_state("unknown")
    end
  end

  describe "last applied cache (for drift detection)" do
    test "stores and retrieves last-applied manifest" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      resource_key = "Deployment/default/my-app"

      manifest = %{
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => %{"name" => "my-app"},
        "spec" => %{"replicas" => 3}
      }

      :ok = Cache.put_last_applied(repo_name, resource_key, manifest)
      assert {:ok, ^manifest} = Cache.get_last_applied(repo_name, resource_key)
    end

    test "returns error for unknown resource" do
      assert {:error, :not_found} = Cache.get_last_applied("repo", "unknown")
    end

    test "lists all last-applied manifests for repo" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"

      manifest1 = %{"kind" => "Deployment", "metadata" => %{"name" => "app1"}}
      manifest2 = %{"kind" => "Service", "metadata" => %{"name" => "app1"}}

      :ok = Cache.put_last_applied(repo_name, "Deployment/default/app1", manifest1)
      :ok = Cache.put_last_applied(repo_name, "Service/default/app1", manifest2)

      manifests = Cache.list_last_applied(repo_name)
      assert length(manifests) == 2

      keys = Enum.map(manifests, fn {key, _} -> key end)
      assert "Deployment/default/app1" in keys
      assert "Service/default/app1" in keys
    end

    test "clears all last-applied manifests for repo" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"

      :ok = Cache.put_last_applied(repo_name, "Deployment/default/app", %{"test" => true})
      :ok = Cache.clear_last_applied(repo_name)

      assert Cache.list_last_applied(repo_name) == []
    end

    test "deletes specific last-applied manifest" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      resource_key = "ConfigMap/default/config"

      :ok = Cache.put_last_applied(repo_name, resource_key, %{"data" => %{}})
      :ok = Cache.delete_last_applied(repo_name, resource_key)

      assert {:error, :not_found} = Cache.get_last_applied(repo_name, resource_key)
    end

    test "updates existing last-applied manifest" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      resource_key = "Deployment/default/app"

      :ok = Cache.put_last_applied(repo_name, resource_key, %{"spec" => %{"replicas" => 1}})
      :ok = Cache.put_last_applied(repo_name, resource_key, %{"spec" => %{"replicas" => 3}})

      assert {:ok, manifest} = Cache.get_last_applied(repo_name, resource_key)
      assert manifest["spec"]["replicas"] == 3
    end
  end

  describe "drift timestamps" do
    test "records and retrieves first seen timestamp" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      resource_key = "Deployment/default/api"

      timestamp = Cache.record_drift_first_seen(repo_name, resource_key)

      assert {:ok, ^timestamp} = Cache.get_drift_first_seen(repo_name, resource_key)
    end

    test "returns same timestamp on subsequent calls" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      resource_key = "Deployment/default/api"

      first = Cache.record_drift_first_seen(repo_name, resource_key)
      Process.sleep(10)
      second = Cache.record_drift_first_seen(repo_name, resource_key)

      assert first == second
    end

    test "returns error for unknown resource" do
      assert {:error, :not_found} = Cache.get_drift_first_seen("unknown", "unknown")
    end

    test "clears drift timestamp for resource" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"
      resource_key = "Deployment/default/api"

      Cache.record_drift_first_seen(repo_name, resource_key)
      :ok = Cache.clear_drift_first_seen(repo_name, resource_key)

      assert {:error, :not_found} = Cache.get_drift_first_seen(repo_name, resource_key)
    end

    test "clears all drift timestamps for repo" do
      repo_name = "test-repo-#{:rand.uniform(1000)}"

      Cache.record_drift_first_seen(repo_name, "Deployment/default/a")
      Cache.record_drift_first_seen(repo_name, "Deployment/default/b")
      :ok = Cache.clear_all_drift_timestamps(repo_name)

      assert {:error, :not_found} = Cache.get_drift_first_seen(repo_name, "Deployment/default/a")
      assert {:error, :not_found} = Cache.get_drift_first_seen(repo_name, "Deployment/default/b")
    end
  end
end
