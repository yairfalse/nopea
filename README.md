# NOPEA

**Lightweight GitOps Controller - Learning Project**

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/elixir-1.16%2B-purple.svg)](https://elixir-lang.org)
[![Tests](https://img.shields.io/badge/tests-171%20passing-green.svg)]()

A GitOps controller for Kubernetes written in Elixir. Built to learn BEAM, OTP supervision trees, and GitOps patterns.

**This is a learning project** - I'm building it to understand:
- How OTP supervision and GenServers work
- ETS for in-memory caching (no Redis, no database)
- Process isolation and crash recovery
- Rust Ports for external process communication
- Kubernetes controller patterns in Elixir

**Current Status**: Core features working - Git sync, K8s apply, drift detection, webhooks.

---

## How It Works

```
Git repo  ──poll/webhook──►  NOPEA  ──apply──►  Kubernetes
```

1. Create a `GitRepository` CRD
2. NOPEA spawns a Worker GenServer for it
3. Worker clones/fetches via Rust Port (libgit2)
4. Worker applies manifests via K8s server-side apply
5. Repeat on webhook or timer

---

## Features

| Feature | Description |
|---------|-------------|
| **One GenServer per Repo** | Process isolation - crash affects only that repo |
| **ETS Cache** | No Redis, no database - pure BEAM |
| **Rust Git Port** | libgit2 for reliable git operations |
| **Three-Way Drift Detection** | Detects manual changes vs git changes |
| **Configurable Healing** | auto/manual/notify policies + grace period |
| **Break-Glass Annotation** | Per-resource opt-out for emergencies |
| **Webhook Support** | GitHub and GitLab push events |
| **CDEvents** | Built-in observability events |
| **Health Endpoints** | `/health` and `/ready` probes |

---

## Quick Start

```bash
# Clone and build
git clone https://github.com/yairfalse/nopea
cd nopea

# Build Rust git binary
cd nopea-git && cargo build --release && cd ..

# Install Elixir deps
mix deps.get

# Run tests
mix test

# Run controller
iex -S mix
```

**Requirements:**
- Elixir 1.16+
- Rust 1.75+
- Kubernetes 1.22+ (for server-side apply)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         BEAM VM                                  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  OTP Application                                           │ │
│  │  ├── Cache (4 ETS tables)                                  │ │
│  │  ├── ULID Generator (monotonic IDs)                        │ │
│  │  ├── CDEvents Emitter (async HTTP queue)                   │ │
│  │  ├── Controller (K8s CRD watcher)                          │ │
│  │  ├── DynamicSupervisor                                     │ │
│  │  │   ├── Worker (repo: my-app)                             │ │
│  │  │   ├── Worker (repo: other-app)                          │ │
│  │  │   └── ...                                               │ │
│  │  └── Webhook Router (Plug/Cowboy)                          │ │
│  └────────────────────────────────────────────────────────────┘ │
│                              │                                   │
│                              ▼                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Git Port (Rust via stdin/stdout msgpack)                  │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**Key Insight**: Worker crash = only that repo affected. Supervisor restarts it.

---

## GitRepository CRD

```yaml
apiVersion: nopea.false.systems/v1alpha1
kind: GitRepository
metadata:
  name: my-app
  namespace: default
spec:
  url: https://github.com/org/my-app.git
  branch: main
  path: deploy/              # subdirectory (optional)
  interval: 5m               # poll interval
  targetNamespace: default   # where to apply
  secretRef:                 # git auth (optional)
    name: git-credentials

  # Healing configuration
  suspend: false             # pause all syncing
  healPolicy: auto           # auto | manual | notify
  healGracePeriod: 5m        # wait before healing manual drift
status:
  lastSyncedCommit: abc123
  lastSyncTime: "2024-01-15T10:30:00Z"
  phase: Synced
```

---

## Sync Triggers

| Trigger | When | Latency |
|---------|------|---------|
| Webhook | Git push | ~1-2s |
| Poll | Timer | configurable |
| Drift | Reconcile loop | 2x poll interval |

---

## Webhook Setup

NOPEA accepts webhooks from GitHub and GitLab:

```bash
# GitHub webhook URL
https://nopea.example.com/webhook/my-app

# Configure secret
NOPEA_WEBHOOK_SECRET=your-secret-here
```

Supports:
- GitHub: HMAC-SHA256 signature verification
- GitLab: Token verification

---

## CDEvents

NOPEA emits CDEvents for observability:

| Event | When |
|-------|------|
| `service.deployed` | First successful sync |
| `service.upgraded` | Sync with new commit |
| `service.removed` | Sync failure |
| `drift.detected` | Manual change detected |

Configure:
```elixir
config :nopea, cdevents_endpoint: "http://event-collector:8080/events"
```

---

## Drift Detection & Healing

NOPEA uses **three-way diff** to detect drift:

| Drift Type | What Happened | Action |
|------------|---------------|--------|
| `git_change` | Git updated | Always apply |
| `manual_drift` | Someone used kubectl | Heal based on policy |
| `conflict` | Both git and cluster changed | Git wins (configurable) |
| `no_drift` | Everything matches | Do nothing |

### Healing Policies

```yaml
spec:
  healPolicy: auto      # Default: heal manual drift immediately
  healPolicy: manual    # Detect and emit events, but don't heal
  healPolicy: notify    # Same as manual + webhook (planned)
```

### Grace Period

Give operators time to commit their hotfix before NOPEA heals it:

```yaml
spec:
  healGracePeriod: 5m   # Wait 5 minutes after detecting drift
```

### Break-Glass Annotation

For emergencies, skip healing on specific resources:

```bash
# Joakim's 3 AM hotfix
kubectl annotate deploy/api nopea.io/suspend-heal=true
kubectl set image deploy/api image=hotfix-v1

# NOPEA will detect drift but skip healing this resource

# Later, remove annotation to resume GitOps
kubectl annotate deploy/api nopea.io/suspend-heal-
```

---

## Project Structure

```
nopea/
├── lib/nopea/
│   ├── application.ex      # OTP Application
│   ├── supervisor.ex       # DynamicSupervisor
│   ├── worker.ex           # GenServer per repo (503 lines)
│   ├── controller.ex       # K8s CRD watcher
│   ├── cache.ex            # ETS storage (4 tables)
│   ├── git.ex              # Rust Port interface
│   ├── k8s.ex              # K8s API client
│   ├── applier.ex          # YAML parsing + K8s apply
│   ├── drift.ex            # Three-way drift detection
│   ├── ulid.ex             # Monotonic ID generator
│   ├── webhook.ex          # Webhook parsing
│   ├── events.ex           # CDEvents builder
│   ├── webhook/router.ex   # Plug HTTP router
│   └── events/emitter.ex   # CDEvents HTTP emitter
├── nopea-git/              # Rust binary for git ops
│   ├── Cargo.toml
│   └── src/main.rs
├── test/                   # ~2800 lines of tests
├── config/
├── deploy/                 # K8s manifests
└── mix.exs
```

---

## Development

### Build & Test

```bash
# Build Rust binary
make rust

# Run tests
mix test

# Run with integration tests
mix test --include integration

# Format
mix format

# Lint
mix credo --strict

# Type check
mix dialyzer
```

### Makefile Targets

```bash
make build      # Build Rust + Elixir
make test       # Run all tests
make docker     # Build Docker image
make deploy     # K8s deployment
make kind-up    # Start Kind cluster
make fmt        # Format both languages
make lint       # Clippy + Credo
```

---

## Tech Stack

| Component | Purpose |
|-----------|---------|
| **Elixir** | Main language, OTP patterns |
| **Rust** | Git operations (nopea-git binary) |
| [k8s](https://hex.pm/packages/k8s) | Kubernetes client |
| [yaml_elixir](https://hex.pm/packages/yaml_elixir) | YAML parsing |
| [req](https://hex.pm/packages/req) | HTTP client |
| [plug_cowboy](https://hex.pm/packages/plug_cowboy) | Webhook server |
| [msgpax](https://hex.pm/packages/msgpax) | Rust Port protocol |
| [git2](https://crates.io/crates/git2) | Rust libgit2 bindings |

---

## Design Decisions

**Why Elixir?**

BEAM provides process isolation, supervision trees, and ETS for free. One GenServer per repo means crash isolation without Redis or external coordination.

**Why Rust for Git?**

libgit2 is battle-tested. Rust Port gives us reliable git operations without shelling out. msgpack protocol over stdin/stdout.

**Why ETS instead of Redis?**

For a GitOps controller, state is recoverable from Git and Kubernetes. ETS is simpler, faster, and survives Worker crashes (but not VM restarts - which is fine).

**Why Three-Way Drift Detection?**

Two-way (git vs live) can't distinguish manual changes from git changes. Three-way (last_applied vs desired vs live) tells us exactly what drifted.

---

## Naming

**Nopea** (Finnish: "fast") - Part of a Finnish tool naming theme:
- **NOPEA** (fast) - GitOps controller
- **KULTA** (gold) - Progressive delivery controller
- **RAUTA** (iron) - Gateway API controller

---

## License

Apache 2.0

---

**Learning Elixir. Learning K8s. Building tools.**
