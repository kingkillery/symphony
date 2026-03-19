# Symphony

**Autonomous agent orchestration for software teams.** Symphony continuously monitors your issue tracker, spins up isolated workspaces, and runs coding agents to completion — so your team manages *work*, not agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

---

## How It Works

1. **Polls Linear** for issues in active states (e.g. `Todo`, `In Progress`).
2. **Creates an isolated workspace** per issue — a fresh clone of your repo.
3. **Launches [Codex](https://openai.com/index/openai-codex/) in App Server mode** inside the workspace.
4. **Sends a workflow prompt** (from your repo's `WORKFLOW.md`) to Codex.
5. **Runs multi-turn agent loops** until the issue reaches a terminal state or the turn limit is hit.
6. **Cleans up** — when an issue moves to `Done`, `Closed`, `Cancelled`, or `Duplicate`, Symphony stops the agent and removes the workspace.

The entire workflow policy — prompt template, concurrency limits, sandbox settings, hooks — lives in a single `WORKFLOW.md` file versioned alongside your code.

---

## Key Features

| Feature | Description |
|---|---|
| **Issue-driven orchestration** | Automatically picks up Linear issues and dispatches agents with bounded concurrency. |
| **Per-issue workspace isolation** | Every issue gets its own cloned repo directory. No cross-contamination between tasks. |
| **Multi-turn execution** | Agents loop until the work is done, with configurable turn limits and retry with exponential backoff. |
| **Configurable sandbox policies** | `read-only`, `workspace-write`, or `danger-full-access` — choose the trust level that fits your environment. |
| **WORKFLOW.md-driven config** | YAML front matter + Liquid-templated Markdown prompt. One file, version-controlled, hot-reloadable. |
| **Workspace lifecycle hooks** | Run custom scripts on `after_create`, `before_remove`, and `before_run` (e.g. clone, install deps, lint). |
| **Live dashboard** | Optional Phoenix LiveView UI at `/` with a JSON API at `/api/v1/*` for operational debugging. |
| **Distributed workers** | SSH-based remote execution across multiple hosts with automatic fallback. |
| **Harness bootstrap** | Automatically scaffolds `AGENTS.md` and agent config for repos that don't have them yet. |
| **Issue creation CLI** | Create Linear issues directly from the command line or from within an agent turn. |

---

## Architecture

```
┌──────────────┐       ┌────────────────┐       ┌───────────────┐
│  Linear API  │◄─────►│  Orchestrator  │──────►│ Agent Runner  │
│  (tracker)   │       │  (poll + dispatch)     │ (per-issue)   │
└──────────────┘       └────────┬───────┘       └───────┬───────┘
                                │                       │
                       ┌────────▼───────┐       ┌───────▼───────┐
                       │   Workspace    │       │  Codex App    │
                       │   Manager      │       │  Server (RPC) │
                       └────────────────┘       └───────────────┘
```

- **Orchestrator** — GenServer that owns the poll loop, dispatch decisions, retry queues, and concurrency limits.
- **Workspace Manager** — Creates deterministic per-issue directories, runs lifecycle hooks, enforces path safety.
- **Agent Runner** — Builds the prompt from the issue + template, launches Codex, and streams results back.
- **Codex App Server** — JSON-RPC 2.0 client over stdio for Codex session management and tool execution.
- **Linear Adapter** — GraphQL client handling issue fetch, state transitions, comments, attachments, and issue creation.
- **Status Dashboard** — Phoenix LiveView + JSON API for real-time observability.

---

## Getting Started

### Prerequisites

Symphony works best in codebases that have adopted [harness engineering](https://openai.com/index/harness-engineering/). You will need:

- A [Linear](https://linear.app) account with a personal API key
- [Codex CLI](https://github.com/openai/codex) installed
- A GitHub repository to target

### Option 1: Build Your Own

Symphony is specified as a language-agnostic service. Tell your favorite coding agent:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

See [`SPEC.md`](SPEC.md) for the full specification.

### Option 2: Use the Elixir Reference Implementation

#### Quick Start (local)

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir

# Install Elixir/Erlang (we recommend mise)
mise trust && mise install

# Build and run
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

#### Quick Start (Docker)

```bash
cd symphony/elixir

docker build -t symphony-elixir:local .

docker run --rm \
  -p 4000:4000 \
  -e LINEAR_API_KEY="$LINEAR_API_KEY" \
  -e SOURCE_REPO_URL="https://github.com/your-org/your-repo" \
  -e SYMPHONY_PORT=4000 \
  -v "$HOME/.codex:/root/.codex" \
  -v "$(pwd)/WORKFLOW.md:/opt/symphony/runtime/WORKFLOW.md:ro" \
  -v symphony-logs:/var/log/symphony \
  -v symphony-workspaces:/var/lib/symphony/workspaces \
  symphony-elixir:local
```

Or use Docker Compose:

```bash
export LINEAR_API_KEY=...
export SOURCE_REPO_URL=https://github.com/your-org/your-repo
docker compose up --build
```

See [`elixir/README.md`](elixir/README.md) for the full setup guide, Docker details, configuration reference, and FAQ.

---

## Configuration

All configuration lives in a single `WORKFLOW.md` file with YAML front matter and a Liquid-templated Markdown body:

```markdown
---
tracker:
  kind: linear
  project_slug: "my-project"
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
  thread_sandbox: workspace-write
---

You are working on issue {{ issue.identifier }}.

Title: {{ issue.title }}
Body: {{ issue.description }}
```

Key configuration sections:

| Section | Purpose |
|---|---|
| `tracker` | Linear project slug, active/terminal states, lifecycle state mappings |
| `workspace` | Root directory for per-issue workspaces |
| `hooks` | Shell scripts for `after_create`, `before_remove`, `before_run` |
| `agent` | Concurrency limits, max turns, per-state limits |
| `codex` | Command, approval policy, sandbox mode |
| `harness` | Auto-bootstrap settings for under-instrumented repos |
| `server` | Host/port for the optional web dashboard |

Environment variables are supported everywhere — use `$VAR` syntax. Paths expand `~` to the home directory.

---

## CLI Reference

**Start the service:**

```bash
./bin/symphony [WORKFLOW.md] [--port 4000] [--logs-root ./log]
```

**Create a Linear issue:**

```bash
./bin/symphony issue create \
  --workflow ./WORKFLOW.md \
  --title "Fix flaky bootstrap sync" \
  --team-id "<linear-team-id>" \
  --project-id "<linear-project-id>" \
  --state-name "Backlog"
```

---

## Project Structure

```
symphony/
├── SPEC.md              # Language-agnostic service specification
├── README.md            # You are here
├── LICENSE              # Apache 2.0
├── .github/             # CI workflows, PR template, media
└── elixir/              # Elixir/OTP reference implementation
    ├── lib/
    │   ├── symphony_elixir/          # Core orchestration
    │   │   ├── orchestrator.ex       # Poll loop, dispatch, retry
    │   │   ├── agent_runner.ex       # Per-issue Codex execution
    │   │   ├── workspace.ex          # Workspace lifecycle
    │   │   ├── workflow.ex           # WORKFLOW.md loader
    │   │   ├── config/schema.ex      # Typed config with Ecto
    │   │   ├── codex/app_server.ex   # JSON-RPC 2.0 Codex client
    │   │   └── linear/adapter.ex     # Linear GraphQL integration
    │   └── symphony_elixir_web/      # Phoenix LiveView dashboard
    ├── test/                         # ExUnit tests
    ├── WORKFLOW.md                   # Reference workflow config
    ├── AGENTS.md                     # Agent guidance
    ├── Dockerfile                    # Multi-stage build
    ├── docker-compose.yml            # Ready-to-run setup
    ├── Makefile                      # Quality gates
    └── mix.exs                       # Dependencies
```

---

## Testing

```bash
cd elixir
make all           # Format check, Credo, tests with coverage, Dialyzer
make e2e           # Live end-to-end against real Linear + Codex
```

The e2e suite creates a temporary Linear project, runs a real agent turn, verifies workspace side effects, and cleans up. Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` to target real SSH hosts, or leave it unset to use disposable Docker SSH containers.

---

## Tech Stack

- **Elixir 1.19** / OTP 28 — supervisor trees, hot code reloading, long-running process management
- **Phoenix LiveView** — real-time dashboard
- **Bandit** — HTTP server
- **Req** — HTTP client for Linear GraphQL
- **Solid** — Liquid template engine
- **Ecto** — typed configuration schemas (no database)

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
