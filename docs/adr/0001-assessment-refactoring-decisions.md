# ADR-0001: Assessment Refactoring Decisions

## Status

Accepted (2026-02-04)

## Context

A three-skill assessment (DDD, QA, Refactoring) was conducted on the Nopea codebase. The assessment revealed:

**Current State (Positive)**:
- ~5,400 lines Elixir across 22 modules
- ~4,600 lines tests across 24 test files
- Strong typespecs throughout
- Consistent error handling (`{:ok, _}` / `{:error, _}`)
- Clear bounded contexts (Git, K8s, Orchestration, Observability)
- Good test pyramid (many unit, fewer integration)

**Issues Identified**:

1. **Primitive Obsession**: Resource keys are strings (`"Kind/Namespace/Name"`) passed through 6+ modules without validation or type safety.

2. **Implicit Value Objects**: Commit SHAs are raw strings with no validation that they're valid 40-char hex.

3. **Long Method**: `Worker.do_sync/1` (57 lines) handles git sync, manifest apply, cache update, CRD status, event emission, and metrics.

4. **Feature Envy**: Worker repeatedly accesses `state.config.*` - the config is unpacked and repacked throughout.

5. **Duplicated Concerns**: Both `Drift.normalize/1` and `Applier.compute_hash/1` deal with manifest processing but aren't coordinated.

6. **Missing Aggregate Boundaries**: Worker acts as aggregate root but invariants aren't explicitly enforced (e.g., status transitions).

**Forces**:
- Nopea is a learning project - changes should be educational
- TDD workflow requires tests before implementation
- Code should remain readable and not over-abstracted
- Future AI-native features will need clean query interfaces

## Decision

We will address the assessment findings in three waves:

### Wave 1: Value Objects (Type Safety)

**Create `Nopea.Domain.ResourceKey`**:
```elixir
defmodule Nopea.Domain.ResourceKey do
  @enforce_keys [:kind, :namespace, :name]
  defstruct [:kind, :namespace, :name]

  @type t :: %__MODULE__{
    kind: String.t(),
    namespace: String.t(),
    name: String.t()
  }

  def new(kind, namespace, name)
  def parse(string) # "Kind/Namespace/Name" -> {:ok, t()} | {:error, reason}
  def to_string(key) # t() -> "Kind/Namespace/Name"
end
```

**Create `Nopea.Domain.CommitSHA`**:
```elixir
defmodule Nopea.Domain.CommitSHA do
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  def new(sha) # Validates 40-char hex
  def valid?(string)
  def short(sha) # First 7 chars
end
```

**Affected Modules**: Applier, Cache, Drift, Worker, Events

### Wave 2: Extract Sync Executor (Single Responsibility)

**Create `Nopea.Sync.Executor`**:
```elixir
defmodule Nopea.Sync.Executor do
  @moduledoc "Executes git->parse->apply cycle"

  def execute(config, repo_path) :: {:ok, Result.t()} | {:error, term()}
end

defmodule Nopea.Sync.Result do
  defstruct [:commit, :applied_resources, :manifest_count, :duration_ms]
end
```

Worker becomes thin orchestrator:
```elixir
def do_sync(state) do
  case Sync.Executor.execute(state.config, repo_path(state.config.name)) do
    {:ok, result} ->
      state
      |> update_state_from_result(result)
      |> update_crd_status(:synced)
      |> emit_events(result)

    {:error, reason} ->
      handle_sync_failure(state, reason)
  end
end
```

### Wave 3: Consolidate Manifest Processing

**Single source of truth for normalization**:
- `Drift.normalize/1` becomes the canonical normalizer
- `Applier.compute_hash/1` delegates to `Drift.compute_hash/1`
- Remove duplicate logic

### Not Doing (Intentionally)

1. **Full Aggregate Pattern**: Over-engineering for current scope. Worker struct is sufficient.

2. **Property-Based Tests**: Nice-to-have, not blocking. Can add later.

3. **Extract ManifestProcessor Module**: Wait until AI-native features clarify what interface is needed.

## Consequences

**Positive**:
- Type safety catches bugs at compile time (ResourceKey, CommitSHA)
- Worker becomes easier to test (Sync.Executor is pure-ish)
- Single normalization logic reduces drift detection bugs
- Prepares codebase for AI-native query interface
- Educational value: demonstrates value object pattern

**Negative**:
- Churn in multiple modules for Wave 1 (one-time cost)
- Slightly more ceremony for resource keys (justified by safety)
- Tests need updating to use new types

**Neutral**:
- No behavior changes - all refactoring, no features
- Existing tests remain valid (may need type updates)

## Implementation Order

1. Write tests for ResourceKey
2. Implement ResourceKey
3. Migrate Applier to use ResourceKey
4. Migrate Cache, Drift, Events, Worker
5. Repeat for CommitSHA
6. Extract Sync.Executor with tests
7. Slim down Worker.do_sync
8. Consolidate normalization
