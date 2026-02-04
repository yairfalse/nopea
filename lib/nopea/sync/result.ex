defmodule Nopea.Sync.Result do
  @moduledoc """
  Result of a successful sync operation.

  Contains all information needed by Worker to update state,
  emit events, and update metrics.
  """

  @enforce_keys [:commit, :applied_resources, :manifest_count, :duration_ms]
  defstruct [:commit, :applied_resources, :manifest_count, :duration_ms]

  @type t :: %__MODULE__{
          commit: String.t(),
          applied_resources: [map()],
          manifest_count: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @doc """
  Creates a new Result.

  ## Parameters

  - `commit` - Git commit SHA
  - `applied_resources` - List of applied K8s resources (with defaults)
  - `duration_ms` - Time taken for sync in milliseconds
  """
  @spec new(String.t(), [map()], non_neg_integer()) :: t()
  def new(commit, applied_resources, duration_ms) do
    %__MODULE__{
      commit: commit,
      applied_resources: applied_resources,
      manifest_count: length(applied_resources),
      duration_ms: duration_ms
    }
  end
end
