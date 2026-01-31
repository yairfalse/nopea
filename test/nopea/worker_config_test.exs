defmodule Nopea.WorkerConfigTest do
  @moduledoc """
  Unit tests for Worker configuration.

  These tests verify configuration behavior without requiring
  the Rust binary or real git operations.
  """

  use ExUnit.Case, async: false

  alias Nopea.Worker

  setup do
    # Store original config value
    original_base_path = Application.get_env(:nopea, :repo_base_path)

    on_exit(fn ->
      # Restore original config
      if original_base_path do
        Application.put_env(:nopea, :repo_base_path, original_base_path)
      else
        Application.delete_env(:nopea, :repo_base_path)
      end
    end)

    :ok
  end

  describe "repo_base_path/0" do
    test "returns configured path when set in application env" do
      custom_path = "/custom/repo/path"
      Application.put_env(:nopea, :repo_base_path, custom_path)

      assert Worker.repo_base_path() == custom_path
    end

    test "returns default path under system tmp when not configured" do
      Application.delete_env(:nopea, :repo_base_path)

      base_path = Worker.repo_base_path()

      # Should be under system temp directory
      assert String.starts_with?(base_path, System.tmp_dir!())
      assert String.ends_with?(base_path, "nopea/repos")
    end
  end

  describe "repo_path/1" do
    test "builds path using configured base path" do
      custom_path = "/custom/repos"
      Application.put_env(:nopea, :repo_base_path, custom_path)

      assert Worker.repo_path("my-repo") == "/custom/repos/my-repo"
    end

    test "sanitizes repo name for filesystem safety" do
      Application.delete_env(:nopea, :repo_base_path)

      path = Worker.repo_path("my/dangerous:repo.name")

      # Should not contain dangerous characters
      refute String.contains?(path, "/dangerous")
      refute String.contains?(path, ":")
      assert String.contains?(path, "my_dangerous_repo_name")
    end
  end
end
