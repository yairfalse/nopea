# NOPEA: Lightweight GitOps Controller

**NOPEA = Aluminum (Finnish) — GitOps without the weight**

---

## CRITICAL: Project Nature

**THIS IS A FUN LEARNING PROJECT**
- **Goal**: Build a BEAM-native GitOps controller
- **Language**: 100% Elixir
- **Status**: Just starting - exploring OTP patterns

---

## PROJECT MISSION

**Mission**: Make GitOps simple with BEAM superpowers

**Core Value Proposition:**

**"GitOps with process isolation - one GenServer per repo, no Redis, no database"**

**The Differentiators:**
1. **BEAM-native** - Process isolation, supervision trees, ETS caching
2. **CDEvents built-in** - Full pipeline observability
3. **Lightweight** - No external dependencies
4. **Works with KULTA** - Progressive delivery integration

---

## ARCHITECTURE

```
┌─────────────────────────────────────────────────────────────────┐
│                    NOPEA                                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   OTP Application                                               │
│   ├── Cache (ETS tables)                                        │
│   ├── Supervisor (DynamicSupervisor)                            │
│   │   ├── Worker (repo: my-app)                                 │
│   │   ├── Worker (repo: other-app)                              │
│   │   └── ...                                                   │
│   ├── Watcher (K8s CRD watch)                                   │
│   └── Webhook.Endpoint (Plug/Cowboy)                            │
│                                                                 │
│   Key Insight: Worker crash = only that repo affected           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## ELIXIR REQUIREMENTS

### Language Requirements
- **THIS IS AN ELIXIR PROJECT** - All code in Elixir
- **OTP PATTERNS** - GenServer, Supervisor, DynamicSupervisor
- **STRONG TYPING** - Use typespecs and dialyzer

---

## ELIXIR CODE QUALITY - INSTANT REJECTION

### No Bare Raises in Production

```elixir
# BANNED
raise "Something went wrong"

# REQUIRED
{:error, :sync_failed}
# OR
{:error, {:git_error, reason}}
```

### No IO.puts in Production

```elixir
# BANNED
IO.puts("Syncing: #{name}")

# REQUIRED
require Logger
Logger.info("Syncing repository", repo: name)
```

### No String-Based State

```elixir
# BANNED
%{phase: "syncing"}

# REQUIRED
defmodule Nopea.Phase do
  @type t :: :pending | :syncing | :synced | :failed
end

%{phase: :syncing}
```

### Always Handle :ok/:error Tuples

```elixir
# BANNED
{:ok, result} = some_function()

# REQUIRED
case some_function() do
  {:ok, result} -> handle_success(result)
  {:error, reason} -> handle_error(reason)
end

# OR with with
with {:ok, repo} <- fetch_repo(name),
     {:ok, manifests} <- parse_manifests(repo) do
  apply_manifests(manifests)
else
  {:error, reason} -> {:error, reason}
end
```

---

## OTP PATTERNS

### GenServer State

```elixir
defmodule Nopea.Worker do
  use GenServer

  defstruct [
    :repo_name,
    :repo_url,
    :branch,
    :last_commit,
    :retry_count,
    :sync_timer
  ]

  @type t :: %__MODULE__{
    repo_name: String.t(),
    repo_url: String.t(),
    branch: String.t(),
    last_commit: String.t() | nil,
    retry_count: non_neg_integer(),
    sync_timer: reference() | nil
  }
end
```

### Supervisor Child Spec

```elixir
defmodule Nopea.Supervisor do
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_worker(git_repository) do
    spec = {Nopea.Worker, git_repository}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_worker(repo_name) do
    case Registry.lookup(Nopea.Registry, repo_name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end
end
```

### ETS Table Creation

```elixir
defmodule Nopea.Cache do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(:commits, [:set, :public, :named_table])
    :ets.new(:manifests, [:set, :public, :named_table])
    :ets.new(:hashes, [:set, :public, :named_table])
    {:ok, %{}}
  end

  def get_last_commit(repo_name) do
    case :ets.lookup(:commits, repo_name) do
      [{^repo_name, commit, _timestamp}] -> {:ok, commit}
      [] -> {:error, :not_found}
    end
  end

  def set_last_commit(repo_name, commit) do
    :ets.insert(:commits, {repo_name, commit, System.system_time()})
    :ok
  end
end
```

---

## TDD Workflow (RED → GREEN → REFACTOR)

**MANDATORY**: All code must follow strict Test-Driven Development

### RED Phase: Write Failing Test First

```elixir
# Step 1: Write test that FAILS (RED)
defmodule Nopea.WorkerTest do
  use ExUnit.Case, async: true

  test "sync_now triggers git fetch and apply" do
    # Arrange
    repo = %{name: "test-repo", url: "https://github.com/org/repo.git"}
    {:ok, pid} = Nopea.Worker.start_link(repo)

    # Act
    result = Nopea.Worker.sync_now(pid)

    # Assert
    assert {:ok, %{commit: _commit}} = result
  end
end

# Step 2: Verify test FAILS
# $ mix test
# test_sync_now_triggers_git_fetch_and_apply ... FAILED (RED phase confirmed)
```

### GREEN Phase: Minimal Implementation

```elixir
# Step 3: Write MINIMAL code to pass test
defmodule Nopea.Worker do
  use GenServer

  def start_link(repo) do
    GenServer.start_link(__MODULE__, repo)
  end

  def sync_now(pid) do
    GenServer.call(pid, :sync_now)
  end

  @impl true
  def init(repo) do
    {:ok, %{repo: repo, last_commit: nil}}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    case do_sync(state.repo) do
      {:ok, commit} ->
        {:reply, {:ok, %{commit: commit}}, %{state | last_commit: commit}}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_sync(repo) do
    # Minimal implementation
    {:ok, "abc123"}
  end
end

# Step 4: Verify tests PASS
# $ mix test
# test_sync_now_triggers_git_fetch_and_apply ... ok (GREEN phase confirmed)
```

### TDD Checklist

- [ ] **RED**: Write failing test first
- [ ] **RED**: Verify `mix test` fails
- [ ] **GREEN**: Write minimal implementation
- [ ] **GREEN**: Verify `mix test` passes
- [ ] **REFACTOR**: Improve design, add edge cases
- [ ] **REFACTOR**: Verify tests still pass
- [ ] **Commit**: Incremental commits

---

## ERROR HANDLING PATTERNS

### Use Tagged Tuples

```elixir
# Good: Explicit error types
@type sync_error ::
  {:git_error, term()} |
  {:parse_error, term()} |
  {:apply_error, term()}

@spec sync(String.t()) :: {:ok, String.t()} | {:error, sync_error()}
def sync(repo_name) do
  with {:ok, repo} <- Git.fetch(repo_name),
       {:ok, manifests} <- Parser.parse(repo.path),
       {:ok, _} <- Applier.apply(manifests) do
    {:ok, repo.commit}
  end
end
```

### Let It Crash (Supervisor Handles)

```elixir
# Worker crashes are OK - supervisor restarts
defmodule Nopea.Worker do
  use GenServer, restart: :permanent

  @impl true
  def handle_info(:poll, state) do
    # If this crashes, supervisor restarts the worker
    # State is lost but that's OK - we recover from K8s/Git
    new_state = do_sync!(state)
    {:noreply, new_state}
  end
end
```

### Backoff on Retries

```elixir
defp schedule_retry(state) do
  delay = min(state.retry_count * 1000, 60_000)
  timer = Process.send_after(self(), :retry_sync, delay)
  %{state | retry_count: state.retry_count + 1, sync_timer: timer}
end

defp reset_retry(state) do
  %{state | retry_count: 0}
end
```

---

## VERIFICATION CHECKLIST

Before EVERY commit:

```bash
# 1. Format - MANDATORY
mix format

# 2. Credo - MANDATORY
mix credo --strict

# 3. Dialyzer - MANDATORY
mix dialyzer

# 4. Tests - MANDATORY
mix test

# 5. No IO.puts in lib/
grep -r "IO.puts\|IO.inspect" lib/

# 6. No bare raises
grep -r "raise \"" lib/

# 7. No TODOs
grep -r "TODO\|FIXME" lib/
```

---

## AI AGENT WORKFLOW

When implementing features:

### Step 1: UNDERSTAND
- Read relevant source files
- Check existing tests
- Ask clarifying questions if unclear

### Step 2: RED (Write Failing Test)
```
Agent: "I'll write the test first. Here's the failing test..."
[Provides complete test code]
Agent: "This should FAIL. Run mix test to verify RED phase."
```

### Step 3: GREEN (Minimal Implementation)
```
Agent: "Here's the minimal implementation to make the test pass..."
[Provides complete implementation]
Agent: "This should PASS. Run mix test to verify GREEN phase."
```

### Step 4: REFACTOR (Improve Code)
```
Agent: "Now let's improve the implementation..."
[Adds error handling, typespecs, docs]
Agent: "Tests should still pass. Run mix test to verify."
```

### Step 5: COMMIT
```
Agent: "Ready to commit. Suggested message:
feat: add Worker GenServer for repo sync

- GenServer per GitRepository
- ETS cache integration
- Exponential backoff on failure
- Tests passing"
```

---

## GIT WORKFLOW

**ALWAYS use feature branches and PRs. Never commit directly to main.**

### Branch Naming
```bash
# Format: type/short-description
feat/add-webhook-endpoint
fix/worker-retry-logic
chore/update-deps
```

### Workflow
1. Create feature branch from main
2. Make changes with incremental commits
3. Push branch to origin
4. Create PR via `gh pr create`
5. Merge after review

### Example
```bash
git checkout -b feat/add-sync-status
# ... make changes ...
git add . && git commit -m "feat: add sync status tracking"
git push -u origin feat/add-sync-status
gh pr create --title "Add sync status tracking" --body "..."
```

---

## NO STUBS, NO TODOs

```elixir
# BANNED
def apply_manifests(manifests) do
  # TODO: implement
  :ok
end

# REQUIRED
def apply_manifests(manifests) do
  Enum.reduce_while(manifests, {:ok, []}, fn manifest, {:ok, acc} ->
    case K8s.Client.apply(manifest) do
      {:ok, result} -> {:cont, {:ok, [result | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end)
end
```

---

## DOCUMENTATION REQUIREMENTS

### Module Docs

```elixir
defmodule Nopea.Worker do
  @moduledoc """
  GenServer that manages a single GitRepository.

  One Worker process per GitRepository CRD. Handles:
  - Git clone/fetch operations
  - YAML manifest parsing
  - Kubernetes apply via server-side apply
  - Status updates on the GitRepository CRD
  - CDEvents emission

  ## State

  - `repo_name` - GitRepository metadata.name
  - `last_commit` - Last successfully synced commit SHA
  - `retry_count` - Current retry attempt (for backoff)

  ## Messages

  - `:poll` - Periodic sync trigger
  - `{:webhook, commit}` - Webhook-triggered sync
  - `:sync_now` - Manual sync request
  """
end
```

### Function Docs

```elixir
@doc """
Trigger immediate sync for this repository.

Returns `{:ok, %{commit: sha}}` on success or `{:error, reason}` on failure.

## Examples

    iex> Nopea.Worker.sync_now(pid)
    {:ok, %{commit: "abc123"}}

    iex> Nopea.Worker.sync_now(pid)
    {:error, {:git_error, "network timeout"}}
"""
@spec sync_now(pid()) :: {:ok, map()} | {:error, term()}
def sync_now(pid) do
  GenServer.call(pid, :sync_now, :timer.seconds(60))
end
```

### Typespecs

```elixir
@type repo_config :: %{
  name: String.t(),
  url: String.t(),
  branch: String.t(),
  path: String.t() | nil,
  interval: pos_integer(),
  target_namespace: String.t()
}

@type state :: %{
  config: repo_config(),
  last_commit: String.t() | nil,
  retry_count: non_neg_integer(),
  sync_timer: reference() | nil
}
```

---

## TESTING PATTERNS

### Use ExUnit Tags

```elixir
defmodule Nopea.WorkerTest do
  use ExUnit.Case, async: true

  @moduletag :worker

  describe "sync_now/1" do
    test "returns commit on success" do
      # ...
    end

    test "returns error on git failure" do
      # ...
    end
  end
end
```

### Mock External Services

```elixir
# Use Mox for mocking
defmodule Nopea.GitBehaviour do
  @callback fetch(String.t()) :: {:ok, map()} | {:error, term()}
  @callback clone(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
end

# In test
defmodule Nopea.WorkerTest do
  import Mox

  setup :verify_on_exit!

  test "handles git error gracefully" do
    Nopea.GitMock
    |> expect(:fetch, fn _url -> {:error, :network_timeout} end)

    {:ok, pid} = Worker.start_link(%{url: "..."})
    assert {:error, {:git_error, :network_timeout}} = Worker.sync_now(pid)
  end
end
```

---

## AGENT CHECKLIST

Before submitting code:

- [ ] Read existing code to understand patterns
- [ ] Wrote failing test first (RED phase)
- [ ] Implemented minimal code (GREEN phase)
- [ ] Added typespecs
- [ ] Added @moduledoc and @doc
- [ ] Used Logger, not IO.puts
- [ ] Used tagged tuples for errors
- [ ] No TODOs or stubs
- [ ] Suggested commit message
- [ ] `mix test` passes
- [ ] `mix format` clean
- [ ] `mix credo --strict` passes

---

## DEFINITION OF DONE

A feature is complete when:

- [ ] Tests written first (TDD)
- [ ] All tests pass
- [ ] Typespecs added
- [ ] Documentation added
- [ ] `mix format` applied
- [ ] `mix credo --strict` passes
- [ ] `mix dialyzer` passes (if configured)
- [ ] Commit message explains what/why

**NO STUBS. NO TODOs. COMPLETE CODE OR NOTHING.**
