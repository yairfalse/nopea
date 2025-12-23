# NOPEA: Lightweight GitOps Controller

**A learning project for BEAM-native GitOps**

---

## PROJECT STATUS

**What's Implemented:**
- Worker GenServer per GitRepository (full sync logic)
- ETS cache (4 tables, no Redis)
- K8s CRD controller (watch + reconcile)
- Git operations via Rust Port (libgit2)
- YAML manifest parsing + K8s server-side apply
- Three-way drift detection
- Webhook endpoint (GitHub + GitLab)
- CDEvents emission (async, retrying)
- ULID generator (monotonic)
- Health/readiness probes

**Code Stats:**
- ~3200 lines Elixir across 15 modules
- ~300 lines Rust (nopea-git binary)
- ~2800 lines tests (14 test files)
- Strong typespecs throughout

---

## ARCHITECTURE OVERVIEW

```
┌─────────────────────────────────────────────────────────────────┐
│                         BEAM VM                                  │
│                                                                  │
│  application.ex                                                  │
│  └── Supervisor tree: Cache, ULID, Emitter, Controller, Workers  │
│                                                                  │
│  worker.ex (503 lines)                                           │
│  ├── GenServer per GitRepository                                 │
│  ├── :startup_sync - initial clone/fetch                         │
│  ├── :poll - periodic git fetch                                  │
│  ├── :reconcile - drift detection (2x poll interval)             │
│  └── :webhook - external trigger                                 │
│                                                                  │
│  cache.ex (4 ETS tables)                                         │
│  ├── :nopea_commits - last synced commit per repo                │
│  ├── :nopea_resources - resource hashes for change detection     │
│  ├── :nopea_sync_states - full sync state                        │
│  └── :nopea_last_applied - for three-way drift detection         │
│                                                                  │
│  git.ex (Rust Port via msgpack)                                  │
│  ├── sync(url, branch, path, depth) - clone or fetch+reset       │
│  ├── files(path, subpath) - list YAML files                      │
│  ├── read(path, file) - read file as base64                      │
│  ├── head(path) - get commit info                                │
│  └── ls_remote(url, branch) - cheap remote check                 │
│                                                                  │
│  drift.ex                                                        │
│  └── three_way_diff(last_applied, desired, live)                 │
│      → :no_drift | {:git_change, diff} | {:manual_drift, diff}   │
└─────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **One GenServer per repo** - Crash isolation, supervisor restarts
2. **ETS not Redis** - State recoverable from Git/K8s, no external deps
3. **Rust Port for Git** - libgit2 reliability, msgpack protocol
4. **Three-way drift** - Distinguishes manual changes from git changes
5. **Async CDEvents** - Queue with exponential backoff retry

---

## ELIXIR REQUIREMENTS

### Absolute Rules

1. **No bare `raise`** - Use `{:error, reason}` tuples
2. **No `IO.puts`** - Use `require Logger; Logger.info(...)`
3. **No string enums** - Use atoms: `:syncing` not `"syncing"`
4. **Always handle errors** - Pattern match `{:ok, _}` and `{:error, _}`

### Error Handling Pattern

```elixir
# BAD
{:ok, result} = some_function()

# GOOD
case some_function() do
  {:ok, result} -> handle_success(result)
  {:error, reason} -> handle_error(reason)
end

# OR with `with`
with {:ok, repo} <- fetch_repo(name),
     {:ok, manifests} <- parse_manifests(repo) do
  apply_manifests(manifests)
else
  {:error, reason} -> {:error, reason}
end
```

### Logging Pattern

```elixir
# BAD
IO.puts("Syncing: #{name}")

# GOOD
require Logger
Logger.info("Syncing repository", repo: name, commit: sha)
Logger.warning("Sync failed", repo: name, error: reason)
```

---

## TDD WORKFLOW

**RED → GREEN → REFACTOR** - Always.

### RED: Write Failing Test First

```elixir
defmodule Nopea.WorkerTest do
  use ExUnit.Case, async: true

  test "sync_now triggers git fetch and apply" do
    repo = %{name: "test-repo", url: "https://github.com/org/repo.git"}
    {:ok, pid} = Nopea.Worker.start_link(repo)

    result = Nopea.Worker.sync_now(pid)

    assert {:ok, %{commit: _}} = result
  end
end
```

### GREEN: Minimal Implementation

Write just enough code to make the test pass.

### REFACTOR: Clean Up

Add typespecs, docs, edge cases. Tests must still pass.

---

## OTP PATTERNS IN THE CODEBASE

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
end
```

### DynamicSupervisor

```elixir
defmodule Nopea.Supervisor do
  use DynamicSupervisor

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

### ETS Tables

```elixir
# Public tables - Worker crashes don't lose data
:ets.new(:nopea_commits, [:set, :public, :named_table])
:ets.new(:nopea_resources, [:set, :public, :named_table])
:ets.new(:nopea_sync_states, [:set, :public, :named_table])
:ets.new(:nopea_last_applied, [:set, :public, :named_table])
```

---

## VERIFICATION CHECKLIST

Before every commit:

```bash
# Format
mix format

# Lint
mix credo --strict

# Type check
mix dialyzer

# Tests
mix test

# No IO.puts
grep -r "IO.puts\|IO.inspect" lib/

# No bare raises
grep -r "raise \"" lib/
```

---

## FILE LOCATIONS

| What | Where |
|------|-------|
| OTP Application | `lib/nopea/application.ex` |
| Worker GenServer | `lib/nopea/worker.ex` |
| DynamicSupervisor | `lib/nopea/supervisor.ex` |
| K8s Controller | `lib/nopea/controller.ex` |
| ETS Cache | `lib/nopea/cache.ex` |
| Rust Port interface | `lib/nopea/git.ex` |
| K8s client | `lib/nopea/k8s.ex` |
| YAML parser + applier | `lib/nopea/applier.ex` |
| Drift detection | `lib/nopea/drift.ex` |
| ULID generator | `lib/nopea/ulid.ex` |
| Webhook parsing | `lib/nopea/webhook.ex` |
| CDEvents builder | `lib/nopea/events.ex` |
| Webhook router | `lib/nopea/webhook/router.ex` |
| CDEvents emitter | `lib/nopea/events/emitter.ex` |
| Rust git binary | `nopea-git/src/main.rs` |
| K8s manifests | `deploy/` |

---

## DEPENDENCIES

### Elixir (mix.exs)

| Package | Purpose |
|---------|---------|
| `k8s` | Kubernetes client |
| `yaml_elixir` | YAML parsing |
| `req` | HTTP client |
| `jason` | JSON encoding |
| `msgpax` | Rust Port protocol |
| `plug_cowboy` | Webhook server |
| `telemetry` | Observability |
| `mox` | Test mocking |

### Rust (nopea-git/Cargo.toml)

| Crate | Purpose |
|-------|---------|
| `git2` | libgit2 bindings |
| `rmp-serde` | MessagePack |
| `base64` | File encoding |
| `thiserror` | Error types |

---

## AGENT INSTRUCTIONS

When working on this codebase:

1. **Read first** - Understand OTP patterns before changing
2. **TDD always** - Write failing test, implement, refactor
3. **No stubs** - Complete implementations only
4. **Typespecs required** - All public functions
5. **Run checks** - `mix format && mix credo --strict && mix test`

**This is a learning project** - exploring OTP patterns and BEAM superpowers. Ask questions if unclear.
