# ADR-0002: AI-Native GitOps

## Status

Proposed

## Context

GitOps tools today are designed for human operators:
- CLI commands (`flux reconcile`, `argocd app sync`)
- Web dashboards (ArgoCD UI)
- YAML-based configuration
- Alert-driven workflows (PagerDuty → human → kubectl)

AI coding assistants (Claude Code, Copilot, Cursor) are becoming primary interfaces for developers. These assistants can:
- Execute shell commands
- Read/write files
- Connect to external tools via protocols (MCP)
- Maintain conversation context
- Reason about complex situations

**The Gap**: No GitOps tool is designed to be operated by AI assistants.

**Opportunity**: Nopea can be the first AI-native GitOps controller - designed from the ground up to be queried, controlled, and reasoned about by AI.

**What "AI-Native" Means**:

1. **Queryable**: AI can ask "what's deployed?" and get structured answers
2. **Controllable**: AI can trigger syncs, rollbacks, suspend healing
3. **Explainable**: AI can understand why drift occurred, what changed
4. **Conversational**: Natural language in, actionable operations out
5. **Context-Rich**: Responses include enough context for AI to make decisions

**Forces**:
- MCP (Model Context Protocol) is Anthropic's standard for tool integration
- Claude Code already supports MCP servers
- GitOps is inherently about state and history - perfect for AI queries
- Drift detection requires judgment - AI can help operators decide
- Rollbacks are scary - AI can provide confidence with context

## Decision

We will make Nopea AI-native through four capabilities:

### 1. MCP Server

Implement Model Context Protocol server exposing Nopea as a tool:

```
┌─────────────────┐     MCP/stdio      ┌─────────────────┐
│   Claude Code   │ ◄────────────────► │   Nopea MCP     │
│   (AI Agent)    │                    │   Server        │
└─────────────────┘                    └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │  Nopea Core     │
                                       │  (Workers,      │
                                       │   Cache, K8s)   │
                                       └─────────────────┘
```

**MCP Tools** (actions AI can take):

| Tool | Input | Output | Use Case |
|------|-------|--------|----------|
| `list_repositories` | filters? | `[{name, status, commit, age}]` | "What repos do you manage?" |
| `get_sync_status` | repo_name | `{status, commit, last_sync, manifests}` | "Is my-app healthy?" |
| `trigger_sync` | repo_name | `{ok, commit}` or `{error, reason}` | "Deploy my-app now" |
| `rollback` | repo_name, target? | `{ok, from, to}` | "Roll back my-app" |
| `check_drift` | repo_name? | `[{resource, drift_type, changes}]` | "Any manual changes?" |
| `get_history` | repo_name, limit? | `[{commit, timestamp, manifests}]` | "What deployed today?" |
| `suspend_healing` | resource_key, duration? | `{ok}` | "Don't revert the hotfix" |
| `resume_healing` | resource_key | `{ok}` | "OK, resume normal ops" |

**MCP Resources** (data AI can read):

| URI | Description |
|-----|-------------|
| `nopea://repositories` | All managed repositories |
| `nopea://repository/{name}` | Single repo with full details |
| `nopea://repository/{name}/manifests` | Current manifests |
| `nopea://repository/{name}/history` | Deployment history |
| `nopea://drift` | All current drift |
| `nopea://drift/{resource_key}` | Specific resource drift details |

### 2. History Tracking

Current state: Nopea tracks current commit but not history.

Required: Track deployment history for AI queries.

```elixir
# New ETS table
:nopea_sync_history

# Schema per entry
%{
  id: ulid,
  repo_name: string,
  commit: CommitSHA.t(),
  previous_commit: CommitSHA.t() | nil,
  timestamp: DateTime.t(),
  manifest_count: integer,
  duration_ms: integer,
  trigger: :poll | :webhook | :manual | :rollback,
  status: :success | :failure,
  error: term | nil
}
```

Enables:
- "What deployed in the last hour?"
- "Show me the last 5 deployments of my-app"
- "When did this commit get deployed?"

### 3. Rollback Capability

Current state: Git.checkout/2 exists but no rollback orchestration.

Required: Full rollback with history awareness.

```elixir
defmodule Nopea.Rollback do
  @doc "Roll back to a specific commit"
  def to_commit(repo_name, commit_sha)

  @doc "Roll back to the previous deployment"
  def to_previous(repo_name)

  @doc "Roll back to state at a specific time"
  def to_time(repo_name, datetime)

  @doc "List available rollback targets"
  def list_targets(repo_name, limit \\ 10)
end
```

Rollback flow:
1. Validate target commit exists in history
2. Git checkout to target commit
3. Parse manifests from that commit
4. Apply to cluster (server-side apply)
5. Record rollback in history
6. Emit CDEvent for rollback

### 4. Structured Query API

Internal API that MCP tools call:

```elixir
defmodule Nopea.Query do
  @doc "Query repositories with optional filters"
  def repositories(opts \\ [])
  # opts: status: [:synced, :failed], namespace: "prod"

  @doc "Get all drifted resources"
  def drifted_resources(opts \\ [])
  # opts: repo: "my-app", drift_type: :manual_drift

  @doc "Query deployment history"
  def deployments(opts \\ [])
  # opts: repo: "my-app", since: datetime, limit: 50

  @doc "Get detailed diff for a drifted resource"
  def drift_details(resource_key)
  # Returns: %{last_applied: map, desired: map, live: map, diff: map}
end
```

### Configuration

Users configure Claude Code to connect:

```json
// ~/.claude/settings.json
{
  "mcpServers": {
    "nopea": {
      "command": "nopea",
      "args": ["mcp"],
      "env": {
        "KUBECONFIG": "~/.kube/config"
      }
    }
  }
}
```

Or for remote Nopea:

```json
{
  "mcpServers": {
    "nopea": {
      "url": "http://nopea.internal:9999/mcp"
    }
  }
}
```

## Consequences

**Positive**:

1. **First-mover**: No GitOps tool has AI-native interface today
2. **Better UX**: Developers ask questions instead of running commands
3. **Safer Operations**: AI provides context before destructive actions
4. **Educational**: Perfect learning project for MCP implementation
5. **Composable**: MCP tools can be combined by AI for complex workflows

**Negative**:

1. **Maintenance**: MCP protocol may evolve, requiring updates
2. **Security**: AI-triggered rollbacks need authorization model
3. **Complexity**: Additional surface area to test and maintain
4. **Dependency**: Ties value proposition to AI assistant adoption

**Risks & Mitigations**:

| Risk | Mitigation |
|------|------------|
| AI triggers accidental rollback | Require confirmation for destructive ops |
| MCP protocol changes | Abstract behind internal API (Query module) |
| Performance with large history | Pagination, time-based pruning |
| Security of AI operations | Respect K8s RBAC, add Nopea-level ACLs |

**Open Questions**:

1. Should rollback require human confirmation via AI prompt?
2. How much history to retain? (Suggest: 100 entries per repo or 30 days)
3. Should MCP server run in-process or as sidecar?
4. HTTP vs stdio for MCP transport?

## Implementation Order

Prerequisites (ADR-0001):
1. ResourceKey value object
2. CommitSHA value object
3. Sync.Executor extraction

AI-Native Features:
1. History tracking (ETS table + Cache API)
2. Query module (internal API)
3. Rollback module
4. MCP server skeleton
5. MCP tools (one at a time, with tests)
6. MCP resources
7. Documentation + examples

## Example Interactions

**Status Check**:
```
User: "Is production healthy?"
Claude: [calls list_repositories, get_sync_status for each]
        "All 3 production repos are synced:
         - api: v2.1.0 (abc123) - 5 min ago
         - web: v3.0.1 (def456) - 2 hours ago
         - worker: v1.5.0 (789ghi) - 1 day ago"
```

**Drift Investigation**:
```
User: "Did anyone change anything manually?"
Claude: [calls check_drift]
        "Yes, 1 resource has manual drift:
         Deployment/prod/api - replicas changed from 3 to 5.
         This happened after your last sync. Looks like
         someone scaled up manually. Want me to preserve
         this or let Nopea heal it back to 3?"
```

**Rollback**:
```
User: "The api is broken, roll it back"
Claude: [calls get_history for api, shows options]
        "I can roll back to:
         1. v2.0.9 (xyz789) - 2 hours ago
         2. v2.0.8 (uvw456) - yesterday
         Which one?"
User: "The first one"
Claude: [calls rollback with xyz789]
        "Done. Rolled back api from v2.1.0 to v2.0.9.
         5 manifests re-applied. Status: synced.
         Watch the pods: kubectl get pods -n prod -w"
```
