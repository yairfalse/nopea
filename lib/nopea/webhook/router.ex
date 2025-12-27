defmodule Nopea.Webhook.Router do
  @moduledoc """
  Plug Router for handling webhook requests.

  ## Endpoints

  - `POST /webhook/:repo` – Receive webhook from GitHub/GitLab
  - `GET /health` – Liveness probe (checks if Cache/ULID processes are alive)
  - `GET /ready` – Readiness probe (checks if Controller is watching CRDs)

  ## Configuration

  This router verifies incoming webhook signatures using a shared secret
  configured under the `:nopea` application:

      # config/config.exs
      import Config

      config :nopea,
        webhook_secret: System.get_env("NOPEA_WEBHOOK_SECRET") || "change-me"

  The `webhook_secret` must match the secret/token configured on the
  webhook provider (e.g. GitHub or GitLab). It is read at runtime via:

      Application.get_env(:nopea, :webhook_secret, "")

  If the secret is missing or does not match, incoming webhooks will be
  rejected with `401` (`invalid_signature`).

  ## Starting the webhook server

  `Nopea.Webhook.Router` is a `Plug.Router` and can be used as the `:plug`
  for a `Plug.Cowboy` HTTP server. A typical setup in your application
  supervision tree might look like this:

      # lib/nopea/application.ex
      def start(_type, _args) do
        children = [
          {
            Plug.Cowboy,
            scheme: :http,
            plug: Nopea.Webhook.Router,
            options: [port: String.to_integer(System.get_env("PORT") || "4001")]
          }
        ]

        opts = [strategy: :one_for_one, name: Nopea.Supervisor]
        Supervisor.start_link(children, opts)
      end

  You can mount the router under a different plug or path if you already
  have a Plug/Cowboy server; it behaves like any other `Plug.Router`.
  """

  use Plug.Router
  require Logger

  alias Nopea.Webhook

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    body_reader: {__MODULE__, :cache_body, []}
  )

  plug(:match)
  plug(:dispatch)

  @doc """
  Custom body reader that caches the raw body for signature verification.
  """
  def cache_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = Plug.Conn.put_private(conn, :raw_body, body)
    {:ok, body, conn}
  end

  # Prometheus metrics endpoint
  get "/metrics" do
    metrics = TelemetryMetricsPrometheus.Core.scrape(:nopea_metrics)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  # Liveness probe - checks if critical processes are alive
  get "/health" do
    checks = %{
      cache: check_process(Nopea.Cache),
      ulid: check_process(Nopea.ULID)
    }

    all_healthy = Enum.all?(checks, fn {_k, v} -> v == "up" end)

    status = if all_healthy, do: "healthy", else: "unhealthy"
    http_status = if all_healthy, do: 200, else: 503

    send_resp(conn, http_status, Jason.encode!(%{status: status, checks: checks}))
  end

  # Readiness probe - checks if we're ready to accept traffic
  get "/ready" do
    case check_controller_ready() do
      {:ok, info} ->
        send_resp(
          conn,
          200,
          Jason.encode!(%{ready: true, watching: info.watching, repos: info.repo_count})
        )

      {:error, reason} ->
        send_resp(conn, 503, Jason.encode!(%{ready: false, watching: false, reason: reason}))
    end
  end

  defp check_process(name) do
    case Process.whereis(name) do
      nil -> "down"
      pid when is_pid(pid) -> if Process.alive?(pid), do: "up", else: "down"
    end
  end

  defp check_controller_ready do
    leader_election_enabled = Application.get_env(:nopea, :enable_leader_election, false)

    # If leader election is enabled, check if we're the leader first
    if leader_election_enabled do
      case check_leader_status() do
        {:ok, :leader} ->
          check_controller_watching()

        {:ok, :not_leader} ->
          {:error, "not_leader"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      check_controller_watching()
    end
  end

  defp check_leader_status do
    case Process.whereis(Nopea.LeaderElection) do
      nil ->
        {:error, "leader_election_not_running"}

      _pid ->
        if Nopea.LeaderElection.leader?() do
          {:ok, :leader}
        else
          {:ok, :not_leader}
        end
    end
  end

  defp check_controller_watching do
    case Process.whereis(Nopea.Controller) do
      nil ->
        {:error, "controller_not_running"}

      pid ->
        try do
          # 2s timeout - K8s probes typically have 1-10s timeouts
          state = GenServer.call(pid, :get_state, 2000)
          # Controller returns Map.from_struct, so use map access
          watching = state[:watch_ref] != nil
          repo_count = map_size(state[:repos] || %{})

          if watching do
            {:ok, %{watching: true, repo_count: repo_count}}
          else
            {:error, "not_watching"}
          end
        catch
          :exit, _ -> {:error, "controller_not_responding"}
        end
    end
  end

  # Valid repo name pattern: alphanumeric, hyphens, underscores, dots
  @repo_name_pattern ~r/^[a-zA-Z0-9._-]+$/

  # Webhook endpoint
  post "/webhook/:repo" do
    repo_name = conn.params["repo"]

    # Validate repo name to prevent log injection
    unless Regex.match?(@repo_name_pattern, repo_name) do
      send_resp(conn, 400, Jason.encode!(%{error: "invalid_repo_name"}))
    else
      headers = conn.req_headers
      raw_body = conn.private[:raw_body] || ""

      provider = Webhook.detect_provider(headers)

      case provider do
        :unknown ->
          Logger.warning("Unknown webhook provider for repo: #{repo_name}")
          send_resp(conn, 400, Jason.encode!(%{error: "unknown_provider"}))

        provider ->
          handle_webhook(conn, repo_name, provider, headers, raw_body)
      end
    end
  end

  # Catch-all for unknown routes
  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not_found"}))
  end

  # Private functions

  defp handle_webhook(conn, repo_name, provider, headers, raw_body) do
    secret = Application.get_env(:nopea, :webhook_secret)
    signature = get_signature(headers, provider)

    # Reject if webhook secret is not configured (security requirement)
    cond do
      is_nil(secret) or secret == "" ->
        Logger.error("Webhook secret not configured, rejecting request")
        send_resp(conn, 500, Jason.encode!(%{error: "webhook_not_configured"}))

      signature == "" ->
        Logger.warning("Missing signature header for webhook: #{repo_name}")
        send_resp(conn, 401, Jason.encode!(%{error: "missing_signature"}))

      true ->
        case Webhook.verify_signature(raw_body, signature, secret, provider) do
          :ok ->
            process_webhook(conn, repo_name, provider)

          {:error, :invalid_signature} ->
            Logger.warning("Invalid signature for webhook: #{repo_name}")
            send_resp(conn, 401, Jason.encode!(%{error: "invalid_signature"}))
        end
    end
  end

  defp process_webhook(conn, repo_name, provider) do
    payload = conn.body_params

    case Webhook.parse_payload(payload, provider) do
      {:ok, parsed} ->
        Logger.info(
          "Webhook received for #{repo_name}: commit=#{parsed.commit}, ref=#{parsed.ref}"
        )

        # Notify the worker if it exists
        notify_worker(repo_name, parsed.commit)

        send_resp(
          conn,
          200,
          Jason.encode!(%{
            status: "received",
            repo: repo_name,
            commit: parsed.commit
          })
        )

      {:error, :unsupported_event} ->
        Logger.debug("Ignoring unsupported event for #{repo_name}")
        send_resp(conn, 200, Jason.encode!(%{status: "ignored", reason: "unsupported_event"}))

      {:error, reason} ->
        Logger.warning("Failed to parse webhook for #{repo_name}: #{inspect(reason)}")
        send_resp(conn, 400, Jason.encode!(%{error: "invalid_payload"}))
    end
  end

  @signature_headers %{
    github: "x-hub-signature-256",
    gitlab: "x-gitlab-token"
  }

  defp get_signature(headers, provider) when provider in [:github, :gitlab] do
    header_name = Map.fetch!(@signature_headers, provider)

    headers
    |> Enum.find(fn {k, _v} -> String.downcase(k) == header_name end)
    |> case do
      {_, value} -> value
      nil -> ""
    end
  end

  defp notify_worker(repo_name, commit) do
    # Check if Registry is available before looking up worker
    case Process.whereis(Nopea.Registry) do
      nil ->
        Logger.debug("Registry not available, skipping worker notification")

      _registry_pid ->
        case Nopea.Worker.whereis(repo_name) do
          nil ->
            Logger.debug("No worker found for repo: #{repo_name}")

          pid ->
            send(pid, {:webhook, commit})
            Logger.info("Notified worker for #{repo_name} about commit: #{commit}")
        end
    end
  end

  @doc """
  Returns a child_spec that can be used to start the webhook router
  under a supervisor, typically from Nopea.Application.

  The HTTP server is always started (required for health/readiness probes).
  Port is configurable via environment variable:

  * NOPEA_HTTP_PORT=port_number (defaults to 4000)
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: __MODULE__,
      options: [port: http_port()]
    )
  end

  defp http_port do
    case System.get_env("NOPEA_HTTP_PORT") do
      nil ->
        4000

      value ->
        case Integer.parse(value) do
          {port, ""} when port > 0 and port < 65_536 -> port
          _ -> 4000
        end
    end
  end
end
