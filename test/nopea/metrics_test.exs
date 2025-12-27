defmodule Nopea.MetricsTest do
  use ExUnit.Case, async: false

  alias Nopea.Metrics

  describe "metrics/0" do
    test "returns list of telemetry metrics definitions" do
      metrics = Metrics.metrics()

      assert is_list(metrics)
      assert length(metrics) > 0

      # Check we have the key metrics
      metric_names = Enum.map(metrics, & &1.name)

      assert [:nopea, :sync, :duration] in metric_names
      assert [:nopea, :sync, :total] in metric_names
      assert [:nopea, :workers, :active] in metric_names
      assert [:nopea, :git, :clone, :duration] in metric_names
      assert [:nopea, :drift, :detected] in metric_names
      assert [:nopea, :leader, :status] in metric_names
    end
  end

  describe "emit_sync_start/1" do
    test "emits telemetry event for sync start" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :sync, :start]
        ])

      Metrics.emit_sync_start(%{repo: "test-repo"})

      assert_receive {[:nopea, :sync, :start], ^ref, %{system_time: _}, %{repo: "test-repo"}}
    end
  end

  describe "emit_sync_stop/2" do
    test "emits telemetry event for sync stop with duration" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :sync, :stop]
        ])

      start_time = System.monotonic_time()
      Process.sleep(10)
      Metrics.emit_sync_stop(start_time, %{repo: "test-repo", status: :ok})

      assert_receive {[:nopea, :sync, :stop], ^ref, %{duration: duration},
                      %{repo: "test-repo", status: :ok}}

      assert duration > 0
    end
  end

  describe "emit_sync_error/2" do
    test "emits telemetry event for sync failure" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :sync, :error]
        ])

      start_time = System.monotonic_time()
      Metrics.emit_sync_error(start_time, %{repo: "test-repo", error: :git_failed})

      assert_receive {[:nopea, :sync, :error], ^ref, %{duration: _},
                      %{repo: "test-repo", error: :git_failed}}
    end
  end

  describe "emit_git_operation/3" do
    test "emits telemetry event for git clone" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :git, :clone, :stop]
        ])

      Metrics.emit_git_operation(:clone, 1500, %{repo: "test-repo"})

      assert_receive {[:nopea, :git, :clone, :stop], ^ref, %{duration: 1500},
                      %{repo: "test-repo"}}
    end

    test "emits telemetry event for git fetch" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :git, :fetch, :stop]
        ])

      Metrics.emit_git_operation(:fetch, 500, %{repo: "test-repo"})

      assert_receive {[:nopea, :git, :fetch, :stop], ^ref, %{duration: 500}, %{repo: "test-repo"}}
    end
  end

  describe "emit_drift_detected/1" do
    test "emits telemetry event for drift detection" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :drift, :detected]
        ])

      Metrics.emit_drift_detected(%{repo: "test-repo", resource: "Deployment/nginx"})

      assert_receive {[:nopea, :drift, :detected], ^ref, %{count: 1},
                      %{repo: "test-repo", resource: "Deployment/nginx"}}
    end
  end

  describe "emit_drift_healed/1" do
    test "emits telemetry event for drift healing" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :drift, :healed]
        ])

      Metrics.emit_drift_healed(%{repo: "test-repo", resource: "Deployment/nginx"})

      assert_receive {[:nopea, :drift, :healed], ^ref, %{count: 1},
                      %{repo: "test-repo", resource: "Deployment/nginx"}}
    end
  end

  describe "emit_leader_change/1" do
    test "emits telemetry event for becoming leader" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :leader, :change]
        ])

      Metrics.emit_leader_change(%{pod: "nopea-abc123", is_leader: true})

      assert_receive {[:nopea, :leader, :change], ^ref, %{status: 1},
                      %{pod: "nopea-abc123", is_leader: true}}
    end

    test "emits telemetry event for losing leadership" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :leader, :change]
        ])

      Metrics.emit_leader_change(%{pod: "nopea-abc123", is_leader: false})

      assert_receive {[:nopea, :leader, :change], ^ref, %{status: 0},
                      %{pod: "nopea-abc123", is_leader: false}}
    end
  end

  describe "set_active_workers/1" do
    test "emits telemetry event for worker count" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :workers, :active]
        ])

      Metrics.set_active_workers(5)

      assert_receive {[:nopea, :workers, :active], ^ref, %{count: 5}, %{}}
    end
  end
end
