defmodule Nopea.Events do
  @moduledoc """
  CDEvents emission for GitOps observability.

  Implements the CDEvents v0.5.0 specification for continuous delivery events.
  Events are built as CloudEvents-compatible structures and can be emitted
  via HTTP to any CDEvents-compatible receiver.

  ## Supported Event Types

  - `:service_deployed` - First successful sync of a repo
  - `:service_upgraded` - Subsequent syncs with new commits
  - `:service_removed` - Service removed from cluster
  - `:environment_created` - Target namespace created
  - `:environment_modified` - Target namespace modified

  ## Example

      event = Events.new(%{
        type: :service_deployed,
        source: "/nopea/worker/my-app",
        subject_id: "my-app-service",
        content: %{
          environment: %{id: "production", source: "/k8s/cluster"},
          artifactId: "pkg:oci/my-app@sha256:abc123"
        }
      })

      {:ok, json} = Events.to_json(event)
  """

  # CloudEvents spec version (CDEvents uses CloudEvents as transport)
  @specversion "1.0"

  @type event_type ::
          :service_deployed
          | :service_upgraded
          | :service_removed
          | :environment_created
          | :environment_modified

  @type subject :: %{
          id: String.t(),
          content: map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          source: String.t(),
          specversion: String.t(),
          timestamp: DateTime.t(),
          subject: subject()
        }

  defstruct [:id, :type, :source, :specversion, :timestamp, :subject]

  @event_type_map %{
    service_deployed: "dev.cdevents.service.deployed.0.3.0",
    service_upgraded: "dev.cdevents.service.upgraded.0.3.0",
    service_removed: "dev.cdevents.service.removed.0.3.0",
    environment_created: "dev.cdevents.environment.created.0.3.0",
    environment_modified: "dev.cdevents.environment.modified.0.3.0",
    # Custom Nopea event for drift detection
    service_drifted: "dev.nopea.service.drifted.0.1.0"
  }

  @doc """
  Creates a new CDEvent with the given parameters.

  ## Parameters

  - `:type` - Event type atom (e.g., `:service_deployed`)
  - `:source` - Event source URI (e.g., "/nopea/worker/my-app")
  - `:subject_id` - Subject identifier
  - `:content` - Event-specific content map

  ## Returns

  A `%Nopea.Events{}` struct with all required CDEvents fields.
  """
  @spec new(map()) :: t()
  def new(%{type: type, source: source, subject_id: subject_id, content: content}) do
    %__MODULE__{
      id: generate_id(),
      type: Map.fetch!(@event_type_map, type),
      source: source,
      specversion: @specversion,
      timestamp: DateTime.utc_now(),
      subject: %{
        id: subject_id,
        content: content
      }
    }
  end

  # ── Builder Functions ──────────────────────────────────────────────────────

  @doc """
  Creates a service.deployed event for first-time sync of a repository.

  ## Parameters

  - `repo_name` - Repository name (used as subject ID and source)
  - `opts` - Map with:
    - `:commit` (required) - Git commit SHA
    - `:namespace` - Target namespace (default: "default")
    - `:manifest_count` - Number of manifests applied
    - `:duration_ms` - Sync duration in milliseconds
    - `:source_url` - Git repository URL

  ## Example

      Events.service_deployed("my-app", %{
        commit: "abc123",
        namespace: "production",
        manifest_count: 5
      })
  """
  @spec service_deployed(String.t(), map()) :: t()
  def service_deployed(repo_name, opts) do
    namespace = Map.get(opts, :namespace, "default")
    commit = Map.fetch!(opts, :commit)

    new(%{
      type: :service_deployed,
      source: "/nopea/worker/#{repo_name}",
      subject_id: repo_name,
      content: %{
        environment: %{id: namespace, source: "/nopea"},
        artifactId: "pkg:git/#{repo_name}@#{commit}",
        manifest_count: opts[:manifest_count],
        duration_ms: opts[:duration_ms],
        source_url: opts[:source_url]
      }
    })
  end

  @doc """
  Creates a service.upgraded event for subsequent syncs with new commits.

  ## Parameters

  - `repo_name` - Repository name
  - `opts` - Map with:
    - `:commit` (required) - New git commit SHA
    - `:namespace` - Target namespace (default: "default")
    - `:previous_commit` - Previous commit SHA
    - `:manifest_count` - Number of manifests applied
    - `:duration_ms` - Sync duration in milliseconds

  ## Example

      Events.service_upgraded("my-app", %{
        commit: "def456",
        previous_commit: "abc123",
        namespace: "production"
      })
  """
  @spec service_upgraded(String.t(), map()) :: t()
  def service_upgraded(repo_name, opts) do
    namespace = Map.get(opts, :namespace, "default")
    commit = Map.fetch!(opts, :commit)

    new(%{
      type: :service_upgraded,
      source: "/nopea/worker/#{repo_name}",
      subject_id: repo_name,
      content: %{
        environment: %{id: namespace, source: "/nopea"},
        artifactId: "pkg:git/#{repo_name}@#{commit}",
        previous_commit: opts[:previous_commit],
        manifest_count: opts[:manifest_count],
        duration_ms: opts[:duration_ms]
      }
    })
  end

  @doc """
  Creates a sync failure event.

  Uses service.removed with outcome: :failure to indicate the sync failed.

  ## Parameters

  - `repo_name` - Repository name
  - `opts` - Map with:
    - `:error` (required) - Error tuple or message
    - `:namespace` - Target namespace (default: "default")
    - `:commit` - Commit that was being synced (if known)

  ## Example

      Events.sync_failed("my-app", %{
        error: {:git_error, "network timeout"},
        namespace: "production"
      })
  """
  @spec sync_failed(String.t(), map()) :: t()
  def sync_failed(repo_name, opts) do
    namespace = Map.get(opts, :namespace, "default")

    new(%{
      type: :service_removed,
      source: "/nopea/worker/#{repo_name}",
      subject_id: repo_name,
      content: %{
        environment: %{id: namespace, source: "/nopea"},
        outcome: "failure",
        error: normalize_error(opts[:error]),
        commit: opts[:commit],
        duration_ms: opts[:duration_ms]
      }
    })
  end

  @doc """
  Creates a service.drifted event when drift is detected.

  ## Parameters

  - `repo_name` - Repository name
  - `opts` - Map with:
    - `:resource_key` (required) - Resource identifier (Kind/Namespace/Name)
    - `:drift_type` (required) - Type of drift (:git_change, :manual_drift, :conflict)
    - `:namespace` - Target namespace (default: "default")
    - `:commit` - Current commit SHA
    - `:action` - Action taken:
      - `:healed` - Drift was corrected by applying desired state
      - `:skipped` - Healing skipped (break-glass annotation or policy)
      - `:reported` - Drift detected but not healed (manual policy)

  ## Example

      Events.drift_detected("my-app", %{
        resource_key: "Deployment/production/my-app",
        drift_type: :manual_drift,
        namespace: "production",
        action: :healed
      })
  """
  @spec drift_detected(String.t(), map()) :: t()
  def drift_detected(repo_name, opts) do
    namespace = Map.get(opts, :namespace, "default")
    drift_type = Map.fetch!(opts, :drift_type)
    resource_key = Map.fetch!(opts, :resource_key)

    new(%{
      type: :service_drifted,
      source: "/nopea/worker/#{repo_name}",
      subject_id: resource_key,
      content: %{
        environment: %{id: namespace, source: "/nopea"},
        repository: repo_name,
        drift_type: Atom.to_string(drift_type),
        commit: opts[:commit],
        action: opts[:action] && Atom.to_string(opts[:action])
      }
    })
  end

  @doc """
  Serializes a CDEvent to JSON.

  Returns `{:ok, json_string}` on success.
  """
  @spec to_json(t()) :: {:ok, String.t()} | {:error, term()}
  def to_json(%__MODULE__{} = event) do
    json_map = %{
      id: event.id,
      type: event.type,
      source: event.source,
      specversion: event.specversion,
      timestamp: DateTime.to_iso8601(event.timestamp),
      subject: event.subject
    }

    Jason.encode(json_map)
  end

  # Generate ULID with fallback when Agent not running (e.g., in tests)
  defp generate_id do
    case Process.whereis(Nopea.ULID) do
      nil -> Nopea.ULID.generate_random()
      _pid -> Nopea.ULID.generate()
    end
  end

  # Convert error tuples/terms to JSON-serializable format
  defp normalize_error({type, message}) when is_atom(type) and is_binary(message) do
    %{type: Atom.to_string(type), message: message}
  end

  defp normalize_error({type, message}) when is_atom(type) do
    %{type: Atom.to_string(type), message: inspect(message)}
  end

  defp normalize_error(errors) when is_list(errors) do
    Enum.map_join(errors, ", ", fn
      {k, v} when is_atom(k) -> "#{k}: #{inspect(v)}"
      other -> inspect(other)
    end)
  end

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(nil), do: nil
  defp normalize_error(error), do: inspect(error)
end
