defmodule Nopea.WorkerConfigValidationTest do
  @moduledoc """
  Tests for Worker config validation on init.

  Verifies that Worker fetches fresh config from K8s CRD on startup,
  rather than trusting the passed config. This prevents stale config
  from Horde CRDT sync during rolling updates.
  """

  use ExUnit.Case, async: false

  import Mox

  alias Nopea.Worker

  # Setup for mocking
  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    # Use mock K8s module
    Application.put_env(:nopea, :k8s_module, Nopea.K8sMock)

    # Start required services
    start_supervised!(Nopea.Cache)
    start_supervised!({Registry, keys: :unique, name: Nopea.Registry})

    # Ensure cluster mode is disabled for these tests
    Application.put_env(:nopea, :cluster_enabled, false)

    on_exit(fn ->
      Application.delete_env(:nopea, :k8s_module)
      Application.delete_env(:nopea, :cluster_enabled)
    end)

    :ok
  end

  describe "Worker.init/1 config validation" do
    test "fetches fresh config from K8s CRD instead of using passed config" do
      # Passed config has STALE values (simulating Horde sync issue)
      stale_config = %{
        name: "test-repo",
        namespace: "default",
        url: "https://github.com/OLD/stale-repo",
        branch: "old-branch",
        path: "old/path",
        target_namespace: "default",
        interval: 300_000,
        suspend: false,
        heal_policy: :auto,
        heal_grace_period: nil
      }

      # K8s CRD has FRESH values (the actual source of truth)
      fresh_crd_resource = %{
        "metadata" => %{
          "name" => "test-repo",
          "namespace" => "default"
        },
        "spec" => %{
          "url" => "https://github.com/NEW/fresh-repo",
          "branch" => "main",
          "path" => "new/path",
          "targetNamespace" => "default",
          "interval" => "5m",
          "suspend" => false,
          "healPolicy" => "auto"
        }
      }

      # The key assertion: get_git_repository is called with the name/namespace,
      # and the returned config should be used (not the stale passed config)
      Nopea.K8sMock
      |> expect(:get_git_repository, fn name, namespace ->
        # Verify we're looking up the right resource
        assert name == "test-repo"
        assert namespace == "default"
        {:ok, fresh_crd_resource}
      end)

      # Trap exits since worker will crash when Git service unavailable
      Process.flag(:trap_exit, true)

      # Start worker with stale config - it should fetch fresh config from K8s
      {:ok, pid} = Worker.start_link(stale_config)

      # Wait for worker to crash (from startup_sync with no Git service)
      # The important thing is the crash message shows it used FRESH config URL
      receive do
        {:EXIT, ^pid, reason} ->
          # The worker tried to sync with the FRESH url from K8s
          # It failed because Git service isn't running, but the error message
          # should reference the fresh URL, not the stale one
          error_msg = inspect(reason)

          # Verify stale URL is NOT used
          refute String.contains?(error_msg, "OLD/stale-repo"),
                 "Worker should NOT use stale URL from passed config"

          # The error contains "noproc" because Git service isn't started
          # This is expected - we're just testing config validation
          assert String.contains?(error_msg, "noproc") or
                   String.contains?(error_msg, "Nopea.Git"),
                 "Expected Git service noproc error"
      after
        2000 ->
          flunk("Worker should have exited from startup_sync failure")
      end
    end

    test "stops gracefully if CRD not found (deleted during startup)" do
      stale_config = %{
        name: "deleted-repo",
        namespace: "default",
        url: "https://github.com/some/repo",
        branch: "main",
        path: nil,
        target_namespace: "default",
        interval: 300_000,
        suspend: false,
        heal_policy: :auto,
        heal_grace_period: nil
      }

      # Mock K8s to return not found (CRD was deleted)
      Nopea.K8sMock
      |> expect(:get_git_repository, fn "deleted-repo", "default" ->
        {:error, :not_found}
      end)

      # Worker should stop with :normal (CRD deleted is expected, not an error)
      assert {:error, :normal} = Worker.start_link(stale_config)
    end
  end
end
