# Integrations

## Linear Issue Tracker (GraphQL API)

- **Endpoint:** `https://api.linear.app/graphql`
- **Auth:** Bearer token via `tracker.api_key` in WORKFLOW.md or `LINEAR_API_KEY` env var
- **Client:** `SymphonyElixir.Linear.Client` using `Req` HTTP library
- **Page size:** 50 issues per request (hardcoded)

### GraphQL Operations
| Operation | Purpose |
|-----------|---------|
| `SymphonyLinearPoll` | Fetch issues by state + project slug |
| `SymphonyLinearIssuesById` | Batch fetch by issue IDs |
| `SymphonyLinearViewer` | Get authenticated user for assignee filtering |
| `commentCreate` | Post comments to issues |
| `issueUpdate` | Change issue state |

### Data Normalization
Raw GraphQL responses → `SymphonyElixir.Linear.Issue` struct with:
- State name extraction from nested `state.name`
- Label flattening from `labels.nodes[].name`
- Blocker extraction from `inverseRelations.nodes` (type=blocks)
- Assignee routing for worker filtering

## Codex AI Agent (App Server Mode)

- **Protocol:** JSON-RPC 2.0 over stdio
- **Process:** Spawned via `Port.open` with configurable `codex.command`
- **Client:** `SymphonyElixir.Codex.AppServer`
- **Auth:** Codex manages its own credentials (`~/.codex/auth.json`)

### Session Lifecycle
1. `initialize` (id=1) — start Codex process
2. `threadStart` (id=2) — begin thread with workspace cwd
3. `turnStart` (id=3) — submit prompt, receive events
4. Bi-directional: tool calls, approvals, token updates
5. Session stop on completion or error

### Dynamic Tools
- `linear_graphql` — client-side tool executed by Symphony (not Codex)
- Dispatched via `SymphonyElixir.Codex.DynamicTool`

### Configuration
```yaml
codex:
  command: codex app-server [options]
  approval_policy: "never" | "on-request" | object
  thread_sandbox: "read-only" | "workspace-write" | "danger-full-access"
  turn_sandbox_policy: {type: "workspaceWrite", writableRoots: [...]}
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
```

## SSH Worker Execution

- **Module:** `SymphonyElixir.SSH`
- **Purpose:** Run agents on remote machines
- **Format:** `user@host:port` or `user@[ipv6]:port`
- **Config file:** `SYMPHONY_SSH_CONFIG` env var (optional)
- **Shell:** Commands wrapped in `bash -lc 'command'`
- **Auth:** System SSH keys only (no password injection)

### Configuration
```yaml
worker:
  ssh_hosts: ["user@host:port", "user@host2"]
  max_concurrent_agents_per_host: 5
```

## HTTP Observability Server

- **Stack:** Phoenix 1.8 + Bandit + LiveView
- **Optional:** disabled if `server.port` not set
- **Host:** configurable, default `127.0.0.1`

### Endpoints
| Route | Purpose |
|-------|---------|
| `GET /` | LiveView dashboard |
| `GET /api/v1/state` | Orchestrator state snapshot (JSON) |
| `GET /api/v1/<identifier>` | Issue details |
| `GET /api/v1/refresh` | Force state refresh |

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `LINEAR_API_KEY` | Linear API token (fallback) |
| `LINEAR_ASSIGNEE` | Assignee filter |
| `SYMPHONY_SSH_CONFIG` | SSH config file path |
| `SYMPHONY_WORKSPACE_ROOT` | Workspace root directory |
| `SYMPHONY_RUN_LIVE_E2E` | Enable E2E tests |

## Data Storage

File-based only (no database):
- **Workspaces:** `~/symphony-workspaces/` (configurable)
- **Logs:** `./log/` (configurable via `--logs-root`)
- **Config:** `WORKFLOW.md` (hot-reloadable)
