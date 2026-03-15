# Architecture

## System Overview

Symphony is an autonomous agent orchestration service that polls Linear for issues, creates isolated per-issue git workspaces, and runs Codex (AI coding agent) in app-server mode via JSON-RPC 2.0 over stdio.

## Supervision Tree

```
SymphonyElixir.Application (one_for_one)
├── Phoenix.PubSub (SymphonyElixir.PubSub)
├── Task.Supervisor (SymphonyElixir.TaskSupervisor)
├── WorkflowStore (GenServer) — monitors WORKFLOW.md for changes
├── Orchestrator (GenServer) — core polling/dispatch loop
├── HttpServer (Phoenix Endpoint) — observability dashboard/API
└── StatusDashboard (GenServer) — terminal UI renderer
```

## Data Flow

```
Linear API (GraphQL)
    │
    ▼
Orchestrator (poll tick)
    │
    ├── Tracker.fetch_candidate_issues()
    │       └── Linear.Client → GraphQL query → [Issue.t()]
    │
    ├── Filter: concurrency limits, state, assignee, blockers
    │
    └── For each dispatchable issue:
            │
            ├── Workspace.create_for_issue(issue, worker_host)
            │       ├── Local: mkdir + git clone
            │       └── Remote: SSH script
            │
            └── spawn_link → AgentRunner.run(issue, recipient)
                    │
                    ├── PromptBuilder.build_prompt(issue, turn)
                    │       └── Liquid template from WORKFLOW.md
                    │
                    ├── AppServer.start_session(workspace, host)
                    │       └── Port.open → Codex subprocess
                    │
                    └── AppServer.run_turn(session, prompt)
                            ├── JSON-RPC 2.0 request/response
                            ├── Tool calls → DynamicTool.execute()
                            └── Token accounting → Orchestrator
```

## Component Relationships

| Component | Depends On | Provides |
|-----------|-----------|----------|
| Orchestrator | Config, Tracker, AgentRunner, StatusDashboard | Issue dispatch, concurrency, retry |
| AgentRunner | Config, Workspace, AppServer, PromptBuilder, Tracker | Single issue execution |
| AppServer | Config, PathSafety, SSH, DynamicTool | Codex JSON-RPC session/turn |
| Workspace | Config, PathSafety, SSH | Isolated execution dirs |
| Linear.Adapter | Linear.Client | Tracker implementation |
| WorkflowStore | Workflow | Config caching, hot-reload |
| StatusDashboard | Orchestrator, ObservabilityPubSub | Terminal UI, snapshots |

## Configuration Flow

```
WORKFLOW.md (YAML front matter + Liquid body)
    → Workflow.load() → parse front matter
    → WorkflowStore (GenServer) → cache, poll for changes
    → Config.settings!() → WorkflowStore.current()
    → Config.Schema.parse() → Ecto validation
    → Schema struct (Tracker, Polling, Workspace, Worker, Agent, Codex, Hooks, Server)
```

## GenServer Patterns

1. **Orchestrator** — tick-driven poll loop, spawns agent tasks, handles `:DOWN`/retry/reconciliation
2. **WorkflowStore** — file-stamp polling (1s), caches last-good config
3. **StatusDashboard** — throttled render loop, PubSub broadcast to web dashboard

## Concurrency Model

- Single Orchestrator GenServer (sequential polling, parallel dispatch)
- Task.Supervisor spawns per-issue AgentRunner processes
- Each agent runs 1..N Codex turns sequentially
- Remote workspaces use blocking SSH commands
- Single-node only (no distributed/clustered logic)

## Message Passing

- **Orchestrator → AgentRunner**: `spawn_link` with issue + callback PID
- **AgentRunner → Orchestrator**: `:worker_runtime_info`, `:codex_worker_update`
- **StatusDashboard**: subscribes to `ObservabilityPubSub` broadcasts
- **DashboardLive**: polls `/api/v1/state` or subscribes to PubSub
