defmodule Nopea.Git.Behaviour do
  @moduledoc """
  Behaviour for Git operations.

  Allows mocking Git operations in tests without requiring the Rust binary.
  """

  @type commit_info :: %{
          sha: String.t(),
          author: String.t(),
          email: String.t(),
          message: String.t(),
          timestamp: integer()
        }

  @callback sync(url :: String.t(), branch :: String.t(), path :: String.t(), depth :: integer()) ::
              {:ok, String.t()} | {:error, String.t()}

  @callback sync(url :: String.t(), branch :: String.t(), path :: String.t()) ::
              {:ok, String.t()} | {:error, String.t()}

  @callback files(path :: String.t(), subpath :: String.t() | nil) ::
              {:ok, [String.t()]} | {:error, String.t()}

  @callback read(path :: String.t(), file :: String.t()) ::
              {:ok, binary()} | {:error, String.t()}

  @callback head(path :: String.t()) ::
              {:ok, commit_info()} | {:error, String.t()}

  @callback checkout(path :: String.t(), sha :: String.t()) ::
              {:ok, String.t()} | {:error, String.t()}

  @callback ls_remote(url :: String.t(), branch :: String.t()) ::
              {:ok, String.t()} | {:error, String.t()}

  @callback decode_content(base64_content :: String.t()) ::
              {:ok, binary()} | {:error, :invalid_base64}
end
