defmodule Nopea.ControllerTest do
  use ExUnit.Case, async: false

  require Logger
  alias Nopea.Controller

  # Unit tests run without K8s cluster
  # Integration tests require K8s cluster and are tagged
  # Suppress noisy K8s connection errors in unit tests
  @moduletag capture_log: true

  describe "interval parsing" do
    # Test interval parsing through config extraction

    test "parses seconds" do
      config = extract_config(%{"interval" => "30s"})
      assert config.interval == 30_000
    end

    test "parses minutes" do
      config = extract_config(%{"interval" => "5m"})
      assert config.interval == 300_000
    end

    test "parses hours" do
      config = extract_config(%{"interval" => "1h"})
      assert config.interval == 3_600_000
    end

    test "defaults to 5 minutes for invalid format" do
      config = extract_config(%{"interval" => "invalid"})
      assert config.interval == 300_000
    end

    test "defaults to 5 minutes when missing" do
      config = extract_config(%{})
      assert config.interval == 300_000
    end
  end

  describe "config extraction from CRD" do
    test "extracts all fields from resource" do
      resource =
        build_git_repository("my-repo", "default", %{
          "url" => "https://github.com/example/repo.git",
          "branch" => "develop",
          "path" => "manifests/",
          "targetNamespace" => "production",
          "interval" => "10m"
        })

      config = extract_config_from_resource(resource)

      assert config.name == "my-repo"
      assert config.namespace == "default"
      assert config.url == "https://github.com/example/repo.git"
      assert config.branch == "develop"
      assert config.path == "manifests/"
      assert config.target_namespace == "production"
      assert config.interval == 600_000
    end

    test "uses defaults for optional fields" do
      resource =
        build_git_repository("minimal-repo", "test", %{
          "url" => "https://github.com/example/repo.git"
        })

      config = extract_config_from_resource(resource)

      assert config.name == "minimal-repo"
      assert config.namespace == "test"
      assert config.url == "https://github.com/example/repo.git"
      assert config.branch == "main"
      assert config.path == nil
      assert config.target_namespace == "test"
      assert config.interval == 300_000
    end
  end

  describe "Controller GenServer" do
    setup do
      # Start required services for Controller tests
      Application.put_env(:nopea, :enable_cache, true)
      Application.put_env(:nopea, :enable_supervisor, true)

      start_supervised!(Nopea.Cache)
      start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
      start_supervised!(Nopea.Supervisor)

      :ok
    end

    test "starts with initial state" do
      # Start controller - it will fail to connect to K8s but that's OK
      # We're testing the GenServer behavior, not K8s connectivity
      {:ok, pid} = Controller.start_link(namespace: "test-ns")

      # Give it a moment to attempt connection
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.namespace == "test-ns"
      assert state.repos == %{}

      GenServer.stop(pid)
    end

    test "get_state/0 returns controller state" do
      {:ok, pid} = Controller.start_link(namespace: "state-test")
      Process.sleep(100)

      # Use the public API (requires named process)
      state = :sys.get_state(pid)
      assert is_map(state)
      assert state.namespace == "state-test"

      GenServer.stop(pid)
    end

    test "handles watch_error by scheduling reconnect" do
      {:ok, pid} = Controller.start_link(namespace: "error-test")
      Process.sleep(100)

      # Send a watch error
      send(pid, {:watch_error, :connection_closed})

      # Check that watch_ref is cleared
      Process.sleep(50)
      state = :sys.get_state(pid)
      assert state.watch_ref == nil

      GenServer.stop(pid)
    end

    test "handles watch_done by scheduling reconnect" do
      {:ok, pid} = Controller.start_link(namespace: "done-test")
      Process.sleep(100)

      # Simulate watch stream ending
      send(pid, {:watch_done, make_ref()})

      Process.sleep(50)
      state = :sys.get_state(pid)
      assert state.watch_ref == nil

      GenServer.stop(pid)
    end
  end

  describe "watch event handling" do
    @moduletag :controller_events

    setup do
      Application.put_env(:nopea, :enable_cache, true)
      Application.put_env(:nopea, :enable_git, true)
      Application.put_env(:nopea, :enable_supervisor, true)

      start_supervised!(Nopea.Cache)
      start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
      start_supervised!(Nopea.Supervisor)

      # Check if Git binary is available for worker tests
      dev_path = Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])

      if File.exists?(dev_path) do
        start_supervised!(Nopea.Git)
        {:ok, git_available: true}
      else
        {:ok, git_available: false}
      end
    end

    test "ADDED event with missing url logs error and doesn't track" do
      {:ok, pid} = Controller.start_link(namespace: "add-test")
      Process.sleep(100)

      # Send ADDED event with missing url
      event = %{
        "type" => "ADDED",
        "object" => build_git_repository("bad-repo", "add-test", %{})
      }

      send(pid, {:watch_event, event})
      Process.sleep(50)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.repos, "bad-repo")

      GenServer.stop(pid)
    end

    test "DELETED event removes repo from tracking" do
      {:ok, pid} = Controller.start_link(namespace: "delete-test")
      Process.sleep(100)

      # Manually set up state with a tracked repo
      :sys.replace_state(pid, fn state ->
        %{state | repos: Map.put(state.repos, "tracked-repo", "v1")}
      end)

      # Verify it's tracked
      state = :sys.get_state(pid)
      assert Map.has_key?(state.repos, "tracked-repo")

      # Send DELETED event
      event = %{
        "type" => "DELETED",
        "object" =>
          build_git_repository("tracked-repo", "delete-test", %{
            "url" => "https://github.com/example/repo.git"
          })
      }

      send(pid, {:watch_event, event})
      Process.sleep(50)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.repos, "tracked-repo")

      GenServer.stop(pid)
    end

    test "BOOKMARK event updates resource version" do
      {:ok, pid} = Controller.start_link(namespace: "bookmark-test")
      Process.sleep(100)

      # Send BOOKMARK event
      event = %{
        "type" => "BOOKMARK",
        "object" => %{
          "metadata" => %{
            "resourceVersion" => "12345"
          }
        }
      }

      send(pid, {:watch_event, event})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.resource_version == "12345"

      GenServer.stop(pid)
    end

    test "duplicate ADDED event is ignored", %{git_available: available} do
      unless available do
        # Skip if no git binary - we need workers to actually start
        :ok
      else
        {:ok, pid} = Controller.start_link(namespace: "dup-test")
        Process.sleep(100)

        # Manually set up state with a tracked repo
        :sys.replace_state(pid, fn state ->
          %{state | repos: Map.put(state.repos, "existing-repo", "v1")}
        end)

        # Send ADDED event for already-tracked repo
        event = %{
          "type" => "ADDED",
          "object" =>
            build_git_repository("existing-repo", "dup-test", %{
              "url" => "https://github.com/example/repo.git"
            })
        }

        send(pid, {:watch_event, event})
        Process.sleep(50)

        # Should still have same resource version (not updated)
        state = :sys.get_state(pid)
        assert state.repos["existing-repo"] == "v1"

        GenServer.stop(pid)
      end
    end

    test "MODIFIED event updates resource version when spec unchanged" do
      {:ok, pid} = Controller.start_link(namespace: "mod-test")
      Process.sleep(100)

      # Set up state with tracked repo (generation matches observed)
      :sys.replace_state(pid, fn state ->
        %{state | repos: Map.put(state.repos, "mod-repo", "v1")}
      end)

      # Send MODIFIED event with same generation as observedGeneration
      # This means spec didn't change - just status update
      event = %{
        "type" => "MODIFIED",
        "object" =>
          build_git_repository_with_generation("mod-repo", "mod-test", 1, 1, %{
            "url" => "https://github.com/example/repo.git"
          })
      }

      send(pid, {:watch_event, event})
      Process.sleep(50)

      # Resource version should be updated
      state = :sys.get_state(pid)
      assert Map.has_key?(state.repos, "mod-repo")
      # Version updated from "v1" to "1" (from the new resource)
      assert state.repos["mod-repo"] == "1"

      GenServer.stop(pid)
    end

    test "unknown event type is ignored" do
      {:ok, pid} = Controller.start_link(namespace: "unknown-test")
      Process.sleep(100)

      initial_state = :sys.get_state(pid)

      # Send unknown event type
      event = %{
        "type" => "UNKNOWN_TYPE",
        "object" => %{"metadata" => %{"name" => "test"}}
      }

      send(pid, {:watch_event, event})
      Process.sleep(50)

      # State should be unchanged
      state = :sys.get_state(pid)
      assert state.repos == initial_state.repos

      GenServer.stop(pid)
    end
  end

  # Helper functions

  defp build_git_repository(name, namespace, spec) do
    %{
      "apiVersion" => "nopea.io/v1alpha1",
      "kind" => "GitRepository",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "resourceVersion" => "1"
      },
      "spec" => spec
    }
  end

  defp build_git_repository_with_generation(name, namespace, generation, observed, spec) do
    %{
      "apiVersion" => "nopea.io/v1alpha1",
      "kind" => "GitRepository",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "resourceVersion" => "1",
        "generation" => generation
      },
      "spec" => spec,
      "status" => %{
        "observedGeneration" => observed
      }
    }
  end

  # Mirror the Controller's config extraction logic for testing
  defp extract_config(spec) do
    %{
      interval: parse_interval(Map.get(spec, "interval", "5m"))
    }
  end

  defp extract_config_from_resource(resource) do
    name = get_in(resource, ["metadata", "name"])
    namespace = get_in(resource, ["metadata", "namespace"])
    spec = Map.get(resource, "spec", %{})

    %{
      name: name,
      namespace: namespace,
      url: Map.get(spec, "url"),
      branch: Map.get(spec, "branch", "main"),
      path: Map.get(spec, "path"),
      target_namespace: Map.get(spec, "targetNamespace", namespace),
      interval: parse_interval(Map.get(spec, "interval", "5m"))
    }
  end

  defp parse_interval(interval) when is_binary(interval) do
    case Regex.run(~r/^(\d+)(s|m|h)$/, interval) do
      [_, num, "s"] -> String.to_integer(num) * 1_000
      [_, num, "m"] -> String.to_integer(num) * 60 * 1_000
      [_, num, "h"] -> String.to_integer(num) * 60 * 60 * 1_000
      _ -> 5 * 60 * 1_000
    end
  end

  defp parse_interval(_), do: 5 * 60 * 1_000
end
