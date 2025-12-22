defmodule Nopea.Webhook do
  @moduledoc """
  Webhook payload parsing and verification for GitHub and GitLab.

  Supports:
  - GitHub push events with HMAC-SHA256 signature verification
  - GitLab push events with token verification
  """

  require Logger

  @type provider :: :github | :gitlab | :unknown
  @type parsed_event :: %{
          commit: String.t(),
          branch: String.t(),
          ref: String.t(),
          repository: String.t()
        }

  # Valid commit SHA patterns: 40 hex chars (SHA-1) or 64 hex chars (SHA-256)
  # Also accepts all-zeros for branch deletion events
  @commit_sha_pattern ~r/^[0-9a-f]{40}$|^[0-9a-f]{64}$/

  @doc """
  Detects the webhook provider from request headers.

  Returns `:github`, `:gitlab`, or `:unknown`.
  """
  @spec detect_provider([{String.t(), String.t()}]) :: provider()
  def detect_provider(headers) do
    headers_map =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
      |> Map.new()

    cond do
      Map.has_key?(headers_map, "x-github-event") ->
        :github

      Map.has_key?(headers_map, "x-gitlab-event") ->
        :gitlab

      true ->
        :unknown
    end
  end

  @doc """
  Parses a webhook payload based on the provider.

  Returns `{:ok, parsed_event}` for push events or `{:error, reason}` otherwise.
  """
  @spec parse_payload(map(), provider()) :: {:ok, parsed_event()} | {:error, atom()}
  def parse_payload(payload, :github) do
    # GitHub push events have "ref" and "after" fields
    with {:has_fields, true} <-
           {:has_fields, Map.has_key?(payload, "ref") and Map.has_key?(payload, "after")},
         commit when is_binary(commit) <- payload["after"],
         {:valid_sha, true} <- {:valid_sha, valid_commit_sha?(commit)} do
      ref = payload["ref"]

      {:ok,
       %{
         commit: commit,
         branch: extract_branch(ref),
         ref: ref,
         repository: get_in(payload, ["repository", "full_name"]) || "unknown"
       }}
    else
      {:has_fields, false} -> {:error, :unsupported_event}
      nil -> {:error, :unsupported_event}
      {:valid_sha, false} -> {:error, :invalid_commit_sha}
    end
  end

  def parse_payload(payload, :gitlab) do
    # GitLab push events have object_kind == "push"
    with {:is_push, true} <- {:is_push, payload["object_kind"] == "push"},
         commit when is_binary(commit) <- payload["after"],
         {:valid_sha, true} <- {:valid_sha, valid_commit_sha?(commit)} do
      ref = payload["ref"]

      {:ok,
       %{
         commit: commit,
         branch: extract_branch(ref),
         ref: ref,
         repository: get_in(payload, ["project", "path_with_namespace"]) || "unknown"
       }}
    else
      {:is_push, false} -> {:error, :unsupported_event}
      nil -> {:error, :unsupported_event}
      {:valid_sha, false} -> {:error, :invalid_commit_sha}
    end
  end

  def parse_payload(_payload, :unknown) do
    {:error, :unknown_provider}
  end

  @doc """
  Verifies the webhook signature/token.

  For GitHub: Verifies HMAC-SHA256 signature in `X-Hub-Signature-256` header.
  For GitLab: Compares `X-Gitlab-Token` header with configured secret.
  """
  @spec verify_signature(String.t(), String.t(), String.t(), provider()) ::
          :ok | {:error, :invalid_signature}
  def verify_signature(payload, signature, secret, :github) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)

    expected_signature = "sha256=#{expected}"

    if Plug.Crypto.secure_compare(expected_signature, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  def verify_signature(_payload, token, secret, :gitlab) do
    if Plug.Crypto.secure_compare(token, secret) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  def verify_signature(_payload, _signature, _secret, :unknown) do
    {:error, :invalid_signature}
  end

  @doc false
  @spec valid_commit_sha?(String.t()) :: boolean()
  def valid_commit_sha?(sha) when is_binary(sha) do
    Regex.match?(@commit_sha_pattern, sha)
  end

  def valid_commit_sha?(_), do: false

  @doc """
  Extracts the branch name from a ref string.

  Used to convert git refs like "refs/heads/main" to just "main"
  for matching against GitRepository branch configurations.

  ## Examples

      iex> Nopea.Webhook.extract_branch("refs/heads/main")
      "main"

      iex> Nopea.Webhook.extract_branch("refs/heads/feature/my-branch")
      "feature/my-branch"
  """
  @spec extract_branch(String.t()) :: String.t()
  def extract_branch("refs/heads/" <> branch), do: branch
  def extract_branch(ref), do: ref
end
