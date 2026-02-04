defmodule Nopea.Domain.CommitSHA do
  @moduledoc """
  Value object representing a Git commit SHA.

  A commit SHA is a 40-character hexadecimal string that uniquely identifies
  a Git commit. This module validates and normalizes SHA values.

  ## Why a Value Object?

  Commit SHAs are passed through many modules (Worker, Cache, Events, Git).
  Using a struct instead of a raw string provides:

  - Validation: Invalid SHAs rejected at creation
  - Normalization: Uppercase converted to lowercase
  - Convenience: `short/1` for display, `to_string/1` for full value
  - Type safety: Can't accidentally pass a branch name where SHA expected

  ## Examples

      iex> {:ok, sha} = CommitSHA.new("abc123def456789012345678901234567890abcd")
      iex> CommitSHA.short(sha)
      "abc123d"

      iex> CommitSHA.valid?("abc123def456789012345678901234567890abcd")
      true

      iex> CommitSHA.valid?("not-a-sha")
      false
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  # Git SHA is always 40 hex characters
  @sha_length 40
  @hex_pattern ~r/^[0-9a-f]{40}$/i

  @doc """
  Creates a new CommitSHA from a string.

  Validates that the input is a 40-character hexadecimal string.
  Normalizes to lowercase.

  ## Examples

      iex> CommitSHA.new("abc123def456789012345678901234567890abcd")
      {:ok, %CommitSHA{value: "abc123def456789012345678901234567890abcd"}}

      iex> CommitSHA.new("invalid")
      {:error, :invalid_sha}
  """
  @spec new(String.t() | nil) :: {:ok, t()} | {:error, :invalid_sha}
  def new(sha) when is_binary(sha) do
    if valid?(sha) do
      {:ok, %__MODULE__{value: String.downcase(sha)}}
    else
      {:error, :invalid_sha}
    end
  end

  def new(_), do: {:error, :invalid_sha}

  @doc """
  Creates a CommitSHA, raising on invalid input.

  Use this when you're confident the input is valid (e.g., from Git output).

  ## Examples

      iex> CommitSHA.from_string!("abc123def456789012345678901234567890abcd")
      %CommitSHA{value: "abc123def456789012345678901234567890abcd"}

      iex> CommitSHA.from_string!("invalid")
      ** (ArgumentError) invalid commit SHA: "invalid"
  """
  @spec from_string!(String.t()) :: t()
  def from_string!(sha) do
    case new(sha) do
      {:ok, commit_sha} -> commit_sha
      {:error, :invalid_sha} -> raise ArgumentError, "invalid commit SHA: #{inspect(sha)}"
    end
  end

  @doc """
  Checks if a string is a valid Git commit SHA.

  A valid SHA is exactly 40 hexadecimal characters (0-9, a-f).

  ## Examples

      iex> CommitSHA.valid?("abc123def456789012345678901234567890abcd")
      true

      iex> CommitSHA.valid?("too-short")
      false
  """
  @spec valid?(String.t() | nil) :: boolean()
  def valid?(sha) when is_binary(sha) do
    byte_size(sha) == @sha_length and Regex.match?(@hex_pattern, sha)
  end

  def valid?(_), do: false

  @doc """
  Returns the short form of the SHA (first 7 characters).

  This is the standard Git short SHA format used in logs and displays.

  ## Examples

      iex> {:ok, sha} = CommitSHA.new("abc123def456789012345678901234567890abcd")
      iex> CommitSHA.short(sha)
      "abc123d"
  """
  @spec short(t()) :: String.t()
  def short(%__MODULE__{value: value}) do
    String.slice(value, 0, 7)
  end

  @doc """
  Returns the full SHA string.

  ## Examples

      iex> {:ok, sha} = CommitSHA.new("abc123def456789012345678901234567890abcd")
      iex> CommitSHA.to_string(sha)
      "abc123def456789012345678901234567890abcd"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value
end

# Implement String.Chars protocol for string interpolation
defimpl String.Chars, for: Nopea.Domain.CommitSHA do
  def to_string(sha) do
    Nopea.Domain.CommitSHA.to_string(sha)
  end
end
