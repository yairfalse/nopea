defmodule Nopea.Sync.ExecutorTest do
  use ExUnit.Case, async: true

  alias Nopea.Sync.{Executor, Result}

  import Mox

  setup :verify_on_exit!

  @test_config %{
    name: "test-repo",
    url: "https://github.com/test/repo.git",
    branch: "main",
    path: nil,
    target_namespace: "default"
  }

  describe "execute/2" do
    test "returns Result with commit and applied resources on success" do
      repo_path = "/tmp/test-repo"
      commit_sha = "abc123def456789012345678901234567890abcd"

      manifests = [
        %{
          "apiVersion" => "v1",
          "kind" => "ConfigMap",
          "metadata" => %{"name" => "test-config", "namespace" => "default"},
          "data" => %{"key" => "value"}
        }
      ]

      # Mock Git operations
      Nopea.GitMock
      |> expect(:sync, fn url, branch, path ->
        assert url == @test_config.url
        assert branch == @test_config.branch
        assert path == repo_path
        {:ok, commit_sha}
      end)
      |> expect(:files, fn path, subpath ->
        assert path == repo_path
        assert subpath == nil
        {:ok, ["config.yaml"]}
      end)
      |> expect(:read, fn path, file ->
        assert path == repo_path
        assert file == "config.yaml"

        yaml =
          "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: test-config\ndata:\n  key: value"

        {:ok, Base.encode64(yaml)}
      end)
      |> expect(:decode_content, fn base64 ->
        Base.decode64(base64)
      end)

      # Mock K8s apply
      Nopea.K8sMock
      |> expect(:apply_manifests, fn applied_manifests, namespace ->
        assert length(applied_manifests) == 1
        assert namespace == "default"
        # Return manifests with K8s defaults added
        {:ok, manifests}
      end)

      result =
        Executor.execute(@test_config, repo_path,
          git_module: Nopea.GitMock,
          k8s_module: Nopea.K8sMock
        )

      assert {:ok, %Result{} = sync_result} = result
      assert sync_result.commit == commit_sha
      assert sync_result.manifest_count == 1
      assert sync_result.applied_resources == manifests
      assert sync_result.duration_ms >= 0
    end

    test "returns error when git sync fails" do
      repo_path = "/tmp/test-repo"

      Nopea.GitMock
      |> expect(:sync, fn _url, _branch, _path ->
        {:error, "network timeout"}
      end)

      result =
        Executor.execute(@test_config, repo_path,
          git_module: Nopea.GitMock,
          k8s_module: Nopea.K8sMock
        )

      assert {:error, {:git_sync_failed, "network timeout"}} = result
    end

    test "returns error when listing files fails" do
      repo_path = "/tmp/test-repo"
      commit_sha = "abc123def456789012345678901234567890abcd"

      Nopea.GitMock
      |> expect(:sync, fn _url, _branch, _path -> {:ok, commit_sha} end)
      |> expect(:files, fn _path, _subpath -> {:error, "path not found"} end)

      result =
        Executor.execute(@test_config, repo_path,
          git_module: Nopea.GitMock,
          k8s_module: Nopea.K8sMock
        )

      assert {:error, {:list_files_failed, "path not found"}} = result
    end

    test "returns error when manifest parsing fails" do
      repo_path = "/tmp/test-repo"
      commit_sha = "abc123def456789012345678901234567890abcd"

      Nopea.GitMock
      |> expect(:sync, fn _url, _branch, _path -> {:ok, commit_sha} end)
      |> expect(:files, fn _path, _subpath -> {:ok, ["bad.yaml"]} end)
      |> expect(:read, fn _path, _file ->
        {:ok, Base.encode64("not: valid: yaml: {")}
      end)
      |> expect(:decode_content, fn base64 ->
        Base.decode64(base64)
      end)

      result =
        Executor.execute(@test_config, repo_path,
          git_module: Nopea.GitMock,
          k8s_module: Nopea.K8sMock
        )

      assert {:error, {:parse_failed, _}} = result
    end

    test "returns error when K8s apply fails" do
      repo_path = "/tmp/test-repo"
      commit_sha = "abc123def456789012345678901234567890abcd"

      Nopea.GitMock
      |> expect(:sync, fn _url, _branch, _path -> {:ok, commit_sha} end)
      |> expect(:files, fn _path, _subpath -> {:ok, ["config.yaml"]} end)
      |> expect(:read, fn _path, _file ->
        yaml = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: test\ndata:\n  key: value"
        {:ok, Base.encode64(yaml)}
      end)
      |> expect(:decode_content, fn base64 -> Base.decode64(base64) end)

      Nopea.K8sMock
      |> expect(:apply_manifests, fn _manifests, _namespace ->
        {:error, {:apply_failed, "forbidden"}}
      end)

      result =
        Executor.execute(@test_config, repo_path,
          git_module: Nopea.GitMock,
          k8s_module: Nopea.K8sMock
        )

      assert {:error, {:apply_failed, "forbidden"}} = result
    end

    test "handles subpath in config" do
      repo_path = "/tmp/test-repo"
      commit_sha = "abc123def456789012345678901234567890abcd"
      config = Map.put(@test_config, :path, "manifests")

      Nopea.GitMock
      |> expect(:sync, fn _url, _branch, _path -> {:ok, commit_sha} end)
      |> expect(:files, fn path, subpath ->
        assert path == repo_path
        assert subpath == "manifests"
        {:ok, ["app.yaml"]}
      end)
      |> expect(:read, fn _path, file ->
        assert file == "manifests/app.yaml"
        yaml = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: test\ndata:\n  key: value"
        {:ok, Base.encode64(yaml)}
      end)
      |> expect(:decode_content, fn base64 -> Base.decode64(base64) end)

      Nopea.K8sMock
      |> expect(:apply_manifests, fn _manifests, _namespace ->
        {:ok, [%{"kind" => "ConfigMap", "metadata" => %{"name" => "test"}}]}
      end)

      result =
        Executor.execute(config, repo_path,
          git_module: Nopea.GitMock,
          k8s_module: Nopea.K8sMock
        )

      assert {:ok, %Result{manifest_count: 1}} = result
    end
  end

  describe "Result struct" do
    test "has required fields" do
      result = %Result{
        commit: "abc123",
        applied_resources: [],
        manifest_count: 0,
        duration_ms: 100
      }

      assert result.commit == "abc123"
      assert result.applied_resources == []
      assert result.manifest_count == 0
      assert result.duration_ms == 100
    end
  end
end
