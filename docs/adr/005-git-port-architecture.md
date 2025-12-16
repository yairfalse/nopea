# ADR-005: Git Operations via Rust Port

**Status:** Accepted
**Date:** 2024-12-16

---

## Context

ALUMIINI needs to perform Git operations (clone, fetch, read files). Options:

1. **Shell out to git CLI** - Simple but slow, credential handling messy
2. **Elixir NIF with libgit2** - Fast but NIF crash = BEAM crash
3. **Rust binary via Erlang Port** - Fast, crash-isolated, clean protocol

---

## Decision

**Use Rust binary communicating via Erlang Port with length-prefixed msgpack protocol.**

```
┌─────────────────────────────────────────────────────────────┐
│                    ALUMIINI (BEAM)                           │
│                                                             │
│   Worker GenServer                                          │
│        │                                                    │
│        │ GenServer.call                                     │
│        ▼                                                    │
│   Alumiini.Git (GenServer)                                  │
│        │                                                    │
│        │ Port (stdin/stdout)                                │
│        │ Length-prefixed msgpack                            │
│        ▼                                                    │
├─────────────────────────────────────────────────────────────┤
│   alumiini-git (Rust process)                               │
│   - git2-rs for operations                                  │
│   - Loops reading requests                                  │
│   - Returns results or errors                               │
└─────────────────────────────────────────────────────────────┘
```

---

## Protocol

### Wire Format

4-byte big-endian length prefix + msgpack payload.

```
┌──────────────┬────────────────────────────┐
│ Length (4B)  │    Msgpack Payload         │
│ Big Endian   │                            │
└──────────────┴────────────────────────────┘
```

### Operations

#### sync
Clone or fetch repository, return HEAD commit.

Request:
```json
{
  "op": "sync",
  "url": "https://github.com/org/repo.git",
  "branch": "main",
  "path": "/data/repos/repo-name",
  "depth": 1
}
```

Response:
```json
{"ok": "abc123def456..."}
```
or
```json
{"err": "failed to fetch: network error"}
```

#### files
List YAML files in directory.

Request:
```json
{
  "op": "files",
  "path": "/data/repos/repo-name",
  "subpath": "deploy/"
}
```

Response:
```json
{"ok": ["configmap.yaml", "deployment.yaml", "service.yaml"]}
```

#### read
Read file contents (base64 encoded).

Request:
```json
{
  "op": "read",
  "path": "/data/repos/repo-name",
  "file": "deploy/deployment.yaml"
}
```

Response:
```json
{"ok": "YXBpVmVyc2lvbjogYXBwcy92MQ..."}
```

---

## Why This Architecture

### Crash Isolation

```elixir
# NIF approach - crash kills BEAM
# nif_git_fetch() -> SIGSEGV -> entire VM dies

# Port approach - crash isolated
# Rust process crashes -> Port exits -> GenServer restarts it
# Other Workers continue unaffected
```

### Performance

- **git2-rs** is fast C library with safe Rust bindings
- Single Rust process handles all repos (no process-per-repo overhead)
- Msgpack is compact and fast to serialize

### Simplicity

- Clear protocol boundary
- Easy to test Rust binary standalone
- Easy to replace/upgrade independently

---

## Implementation

### Rust Binary

```rust
// alumiini-git/src/main.rs
fn main() {
    loop {
        let request = read_request();  // Length-prefixed msgpack from stdin
        let response = handle(request);
        write_response(response);      // Length-prefixed msgpack to stdout
    }
}
```

### Elixir Port Wrapper

```elixir
defmodule Alumiini.Git do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def sync(url, branch, path, depth \\ 1) do
    GenServer.call(__MODULE__, {:sync, url, branch, path, depth}, 300_000)
  end

  @impl true
  def init(_) do
    port = Port.open({:spawn_executable, git_binary_path()}, [
      :binary,
      {:packet, 4},  # 4-byte length prefix
      :exit_status
    ])
    {:ok, %{port: port, pending: %{}}}
  end

  @impl true
  def handle_call({:sync, url, branch, path, depth}, from, state) do
    request = Msgpax.pack!(%{op: "sync", url: url, branch: branch, path: path, depth: depth})
    Port.command(state.port, request)
    {:noreply, %{state | pending: Map.put(state.pending, :current, from)}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    response = Msgpax.unpack!(data)
    {from, pending} = Map.pop(state.pending, :current)
    GenServer.reply(from, parse_response(response))
    {:noreply, %{state | pending: pending}}
  end
end
```

---

## Consequences

### Positive
- Crash isolation preserved (Git crash doesn't kill BEAM)
- High performance with git2-rs
- Clean protocol boundary
- Easy to test components independently
- Can upgrade Rust binary without Elixir changes

### Negative
- Two languages to maintain
- Build complexity (need Rust toolchain)
- Larger container image (~20MB for Rust binary)

### Mitigations
- Dockerfile handles multi-stage build
- CI builds both components
- Integration tests verify protocol compatibility

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| Shell to git CLI | Simple | Slow, credential mess |
| Elixir NIF | Fast, single language | NIF crash = VM crash |
| **Rust Port (chosen)** | Fast, crash-isolated | Two languages |
| Go binary | K8s ecosystem | Less performant than Rust |

---

**Crash isolation. Clean protocol. Fast operations.**
