defmodule Nopea.Webhook.Router do
  @moduledoc """
  Plug Router for handling webhook requests.

  Endpoints:
  - POST /webhook/:repo - Receive webhook from GitHub/GitLab
  - GET /health - Health check endpoint
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

  # Health check endpoint
  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
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
end
