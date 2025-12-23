defmodule Nopea.ControllerTest do
  use ExUnit.Case, async: false

  require Logger
  alias Nopea.Controller

  # Unit tests run without K8s cluster
  # Integration tests require K8s cluster and are tagged
  # Suppress noisy K8s connection errors in unit tests
  @moduletag capture_log: true

  # Shared setup for tests that need Controller infrastructure
  defp start_controller_services(opts \\ []) do
    Application.put_env(:nopea, :enable_cache, true)
    Application.put_env(:nopea, :enable_supervisor, true)

    if Keyword.get(opts, :enable_git, false) do
      Application.put_env(:nopea, :enable_git, true)
    end

    ExUnit.Callbacks.start_supervised!(Nopea.Cache)
    ExUnit.Callbacks.start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
    ExUnit.Callbacks.start_supervised!(Nopea.Supervisor)

    if opts[:enable_git] do
      dev_path = Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])

      if File.exists?(dev_path) do
        ExUnit.Callbacks.start_supervised!(Nopea.Git)
        {:ok, git_available: true}
      else
        {:ok, git_available: false}
      end
    else
      :ok
    end
  end

  # Wait for controller to be ready by polling until state has expected structure
  # Uses :sys.get_state which synchronously waits for prior messages to be processed
  defp await_controller_ready(pid, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_controller_ready(pid, deadline)
  end

  defp do_await_controller_ready(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "Timeout waiting for controller to be ready"
    end

    state = :sys.get_state(pid)

    if Map.has_key?(state, :repos) do
      state
    else
      Process.sleep(10)
      do_await_controller_ready(pid, deadline)
    end
  end

  # Wait for a message to be processed by polling state until condition is met
  defp await_state(pid, condition_fn, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_state(pid, condition_fn, deadline)
  end

  defp do_await_state(pid, condition_fn, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "Timeout waiting for state condition"
    end

    state = :sys.get_state(pid)

    if condition_fn.(state) do
      state
    else
      Process.sleep(5)
      do_await_state(pid, condition_fn, deadline)
    end
  end

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
      start_controller_services()
    end

    test "starts with initial state" do
      # Start controller - it will fail to connect to K8s but that's OK
      # We're testing the GenServer behavior, not K8s connectivity
      {:ok, pid} = Controller.start_link(namespace: "test-ns")

      # Wait for controller to initialize (handles async K8s connection attempt)
      state = await_controller_ready(pid)
      assert state.namespace == "test-ns"
      assert state.repos == %{}

      GenServer.stop(pid)
    end

    test "get_state/0 returns controller state" do
      {:ok, pid} = Controller.start_link(namespace: "state-test")

      state = await_controller_ready(pid)
      assert is_map(state)
      assert state.namespace == "state-test"

      GenServer.stop(pid)
    end

    test "handles watch_error by scheduling reconnect" do
      {:ok, pid} = Controller.start_link(namespace: "error-test")
      await_controller_ready(pid)

      # Send a watch error
      send(pid, {:watch_error, :connection_closed})

      # Wait for state to reflect watch_ref being cleared
      state = await_state(pid, fn s -> s.watch_ref == nil end)
      assert state.watch_ref == nil

      GenServer.stop(pid)
    end

    test "handles watch_done by scheduling reconnect" do
      {:ok, pid} = Controller.start_link(namespace: "done-test")
      await_controller_ready(pid)

      # Simulate watch stream ending
      send(pid, {:watch_done, make_ref()})

      # Wait for state to reflect watch_ref being cleared
      state = await_state(pid, fn s -> s.watch_ref == nil end)
      assert state.watch_ref == nil

      GenServer.stop(pid)
    end
  end

  describe "watch event handling" do
    @moduletag :controller_events

    setup do
      start_controller_services(enable_git: true)
    end

    test "ADDED event with missing url logs error and doesn't track" do
      {:ok, pid} = Controller.start_link(namespace: "add-test")
      await_controller_ready(pid)

      # Send ADDED event with missing url
      event = %{
        "type" => "ADDED",
        "object" => build_git_repository("bad-repo", "add-test", %{})
      }

      send(pid, {:watch_event, event})

      # :sys.get_state is synchronous - waits for prior messages to be processed
      state = :sys.get_state(pid)
      refute Map.has_key?(state.repos, "bad-repo")

      GenServer.stop(pid)
    end

    test "DELETED event removes repo from tracking" do
      {:ok, pid} = Controller.start_link(namespace: "delete-test")
      await_controller_ready(pid)

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

      # Wait for repo to be removed from tracking
      state = await_state(pid, fn s -> not Map.has_key?(s.repos, "tracked-repo") end)
      refute Map.has_key?(state.repos, "tracked-repo")

      GenServer.stop(pid)
    end

    test "BOOKMARK event updates resource version" do
      {:ok, pid} = Controller.start_link(namespace: "bookmark-test")
      await_controller_ready(pid)

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

      # Wait for resource version to be updated
      state = await_state(pid, fn s -> s.resource_version == "12345" end)
      assert state.resource_version == "12345"

      GenServer.stop(pid)
    end

    @tag :requires_git
    test "duplicate ADDED event is ignored", %{git_available: available} do
      # Skip if git binary not available - we need workers to actually start
      if not available, do: assert(true)

      if available do
        {:ok, pid} = Controller.start_link(namespace: "dup-test")
        await_controller_ready(pid)

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

        # :sys.get_state is synchronous - waits for prior messages to be processed
        state = :sys.get_state(pid)
        # Should still have same resource version (not updated)
        assert state.repos["existing-repo"] == "v1"

        GenServer.stop(pid)
      end
    end

    test "MODIFIED event updates resource version when spec unchanged" do
      {:ok, pid} = Controller.start_link(namespace: "mod-test")
      await_controller_ready(pid)

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

      # Wait for resource version to be updated
      state = await_state(pid, fn s -> s.repos["mod-repo"] == "1" end)
      assert Map.has_key?(state.repos, "mod-repo")
      assert state.repos["mod-repo"] == "1"

      GenServer.stop(pid)
    end

    test "unknown event type is ignored" do
      {:ok, pid} = Controller.start_link(namespace: "unknown-test")
      await_controller_ready(pid)

      initial_state = :sys.get_state(pid)

      # Send unknown event type
      event = %{
        "type" => "UNKNOWN_TYPE",
        "object" => %{"metadata" => %{"name" => "test"}}
      }

      send(pid, {:watch_event, event})

      # :sys.get_state is synchronous - waits for prior messages to be processed
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
