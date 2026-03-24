# Symphony Specification - Obsidian Plugin Edition

**Status:** Draft v1.2
**Runtime:** Obsidian community plugin, desktop-only
**Purpose:** Define a plugin-embedded orchestration system that runs coding agents against Markdown-defined project issues inside an Obsidian vault.

---

## 0. Platform, packaging, and support target

Symphony is an **Obsidian community plugin** implemented in TypeScript and packaged with a standard `manifest.json`.

### 0.1 Required packaging

`manifest.json` MUST include at least:

- `id`
- `name`
- `version`
- `description`
- `author`
- `minAppVersion`
- `isDesktopOnly`

Rules:

- `id` MUST NOT contain the string `obsidian`.
- For local development, the plugin folder name SHOULD match the manifest `id`.
- If the plugin is published and a later release changes `minAppVersion`, the repository SHOULD include or update `versions.json` accordingly.

### 0.2 Desktop-only support target

**v1 MUST be desktop-only** and MUST set:

```json
{
  "isDesktopOnly": true
}
```

Reason:

- Symphony launches external coding-agent processes.
- Symphony uses desktop filesystem paths for workspaces and logs.
- Symphony may use Node/Electron APIs for process execution and host filesystem access.

Mobile support is explicitly out of scope for v1.

### 0.3 Release disclosures

If Symphony is distributed, its README and release metadata SHOULD clearly disclose:

- external process execution
- network use
- files written outside the vault
- API key or account requirements
- telemetry policy
- whether the plugin is open or closed source

---

## 1. Problem statement

Symphony is an embedded orchestration runtime that runs **inside Obsidian**.

Instead of polling an external issue tracker as its primary source of work, Symphony:

- reads issue notes from a configured vault folder
- creates or reuses a deterministic per-issue workspace
- launches a coding-agent session in that workspace
- reconciles issue state continuously
- writes operational output back through safe plugin-controlled paths

The plugin solves these operational problems:

- It turns issue execution into a repeatable in-app workflow instead of ad hoc scripts.
- It isolates agent execution in per-issue workspaces.
- It keeps workflow policy in a repository- or vault-owned `WORKFLOW.md`.
- It provides enough observability to operate multiple concurrent agent runs from inside Obsidian.

### 1.1 Project-related task rule

Any task added to the configured Obsidian issue folder that is marked or understood as
project-related SHOULD be treated as eligible work and dispatched by Symphony when it passes the
normal workflow and blocker checks.

Rules:

- "Project-related" means the task belongs to the active Symphony project scope, not an unrelated personal note.
- Project-related tasks MUST NOT be skipped just because they originated in Obsidian instead of an external tracker.
- If a task is ambiguous, the orchestrator SHOULD surface it for human review instead of silently ignoring it.
- Non-project notes MAY remain visible in the vault but SHOULD be ignored by the dispatcher.

Important boundary:

- Symphony is a scheduler, runner, vault issue reader, and optional tracker sync bridge.
- Business-specific issue mutations are typically performed by the coding agent through plugin-advertised tools, not hardcoded orchestrator logic.
- A successful run may end in a workflow-defined handoff state such as `Human Review`, not necessarily `Done`.

---

## 2. Goals and non-goals

### 2.1 Goals

- Poll the vault issue source on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative runtime state for dispatch, retries, and reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when note state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from a vault-owned `WORKFLOW.md`.
- Expose operator-visible observability in Obsidian.
- Support restart recovery without requiring a database.

### 2.2 Non-goals

- Rich multi-tenant control plane.
- Distributed job scheduling.
- A required external web service.
- Hardcoding business rules for PR links, comments, or workflow transitions.
- Mandating one approval or sandbox posture for all deployments.
- Mobile support in v1.

---

## 3. System overview

### 3.1 Main components

1. **Workflow Loader**
   - Reads `WORKFLOW.md` from the vault.
   - Parses YAML front matter and prompt body.
   - Returns `{ config, prompt_template }`.
2. **Config Layer**
   - Exposes typed getters over workflow config plus plugin settings.
   - Applies defaults and environment-variable indirection.
   - Performs dispatch preflight validation.
3. **Vault Issue Provider**
   - Discovers issue notes under a configured vault folder.
   - Normalizes issue notes into the stable issue model.
   - Fetches candidate issues, issue states by ID, and issues by state.
4. **Orchestrator**
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Tracks session metrics and retry state.
5. **Workspace Manager**
   - Maps issue identifiers to external workspace paths.
   - Ensures per-issue workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.
6. **Agent Runner**
   - Prepares the workspace.
   - Builds the prompt.
   - Launches the coding-agent app-server client.
   - Streams updates back to the orchestrator.
7. **Vault Writer**
   - Performs plugin-controlled mutations to issue notes and related vault content.
   - Enforces that vault note mutations use Obsidian APIs rather than direct agent writes.
8. **Dashboard View**
   - Presents running sessions, retries, failures, totals, and issue-specific details.
9. **Logging**
   - Emits structured logs to one or more configured sinks.
10. **Optional HTTP Server**
   - Exposes a local dashboard and JSON state API if enabled.
11. **Optional Tracker Sync Adapter**
   - Syncs issue-note metadata with systems such as Linear if configured.

### 3.2 Abstraction layers

1. **Policy layer**
   - `WORKFLOW.md` prompt body
   - Team-specific workflow rules
2. **Configuration layer**
   - typed getters
   - defaults
   - host-local overrides
   - path normalization
3. **Coordination layer**
   - polling
   - issue eligibility
   - concurrency
   - retries
   - reconciliation
4. **Execution layer**
   - workspace lifecycle
   - agent subprocess
   - protocol handling
5. **Vault integration layer**
   - issue discovery
   - note parsing
   - note updates
   - event-driven invalidation
6. **Optional tracker integration layer**
   - tracker sync
   - raw GraphQL tool bridge
7. **Observability layer**
   - logs
   - dashboard
   - notices
   - optional HTTP API
8. **Obsidian host layer**
   - plugin lifecycle
   - settings tab
   - commands
   - registered view
   - event registration

---

## 4. Core domain model

### 4.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability.

Fields:

- `id` (string)
  - Stable issue ID.
  - Required.
  - Source: frontmatter `id`.
- `identifier` (string)
  - Human-readable issue key, for example `ABC-123`.
  - Required.
  - Source: frontmatter `identifier`.
- `title` (string)
  - Required for dispatch eligibility.
  - Source precedence:
    1. frontmatter `title`
    2. first H1 in body
    3. file basename
- `description` (string or null)
  - Markdown body after front matter.
- `priority` (integer or null)
- `state` (string)
- `branch_name` (string or null)
- `url` (string or null)
- `labels` (list of strings)
  - normalized to lowercase
- `blocked_by` (list of blocker refs)
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)
- `note_path` (string)
  - normalized vault-relative path to the issue note
- `note_basename` (string)

### 4.1.1 Blocker ref

Each blocker ref contains:

- `id` (string or null)
- `identifier` (string or null)
- `state` (string or null)

### 4.2 Workflow definition

Parsed `WORKFLOW.md` payload:

- `config` (map)
- `prompt_template` (string)

### 4.3 Plugin settings

Host-local settings stored via Obsidian plugin data.

Recommended fields:

- `workflow_file_path` (vault-relative path)
- `desktop_workspace_root` (absolute OS path)
- `desktop_log_root` (absolute OS path)
- `auto_start` (boolean)
- `dashboard_open_on_start` (boolean)
- `http_port_override` (integer or null)
- `allow_workspace_inside_vault` (boolean, default false)

### 4.4 Service config

Typed runtime values derived from:

- plugin settings
- workflow front matter
- environment-variable indirection
- defaults

### 4.5 Workspace

Logical workspace record:

- `path`
- `workspace_key`
- `created_now`

### 4.6 Run attempt

- `issue_id`
- `issue_identifier`
- `attempt`
- `workspace_path`
- `started_at`
- `status`
- `error`

### 4.7 Live session

- `session_id`
- `thread_id`
- `turn_id`
- `codex_app_server_pid`
- `last_codex_event`
- `last_codex_timestamp`
- `last_codex_message`
- `codex_input_tokens`
- `codex_output_tokens`
- `codex_total_tokens`
- `last_reported_input_tokens`
- `last_reported_output_tokens`
- `last_reported_total_tokens`
- `turn_count`

### 4.8 Retry entry

- `issue_id`
- `identifier`
- `attempt`
- `due_at_ms`
- `timer_handle`
- `error`

### 4.9 Orchestrator runtime state

- `poll_interval_ms`
- `max_concurrent_agents`
- `running`
- `claimed`
- `retry_attempts`
- `completed`
- `codex_totals`
- `codex_rate_limits`
- `issue_index_generation`
- `pending_reconcile_reason`

### 4.10 Persisted plugin state

Minimal plugin-owned persisted state may include:

- plugin settings
- last known good workflow digest
- stable `issue_id -> workspace_key` mapping
- dashboard UI preferences
- recent non-sensitive error summary

No database is required.

---

## 5. Stable identifiers and normalization rules

- **Issue ID**
  - use as the primary internal key
- **Issue Identifier**
  - use for human-readable logs and workspace naming
- **Workspace Key**
  - if a persisted mapping exists for `issue.id`, reuse it
  - otherwise derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`, then persist that mapping
- **Normalized Issue State**
  - compare after `trim` + `lowercase`
- **Session ID**
  - `<thread_id>-<turn_id>`
- **Vault paths**
  - user-defined vault-relative paths MUST be normalized before use

User-defined paths should be normalized with `normalizePath()`, plugin-owned state should use `loadData()` / `saveData()`, and code must not hardcode `.obsidian` when the config directory is needed because `Vault.configDir` can differ. ([Developer Documentation](https://docs.obsidian.md/oo/plugin "https://docs.obsidian.md/oo/plugin"))

---

## 6. Obsidian lifecycle contract

### 6.1 Startup

`onload()` MUST remain lightweight.

Allowed in `onload()`:

- load plugin settings
- register commands
- register the dashboard view
- register the settings tab
- register ribbon and status-bar items
- register lightweight in-memory services

Heavy work MUST be deferred until `workspace.onLayoutReady()`:

- initial issue indexing
- workflow validation
- startup terminal cleanup
- workspace mapping load
- orchestrator startup
- view hydration
- event-driven issue watchers that must ignore vault bootstrap noise

### 6.2 Event and timer registration

- Vault and workspace listeners MUST be registered using `registerEvent()`.
- Intervals and recurring timers MUST be registered using `registerInterval()`.
- One-shot retry timers MAY also be tracked manually, but they MUST be disposed on unload.

### 6.3 Unload

`onunload()` MUST:

- stop active workers
- cancel timers
- release event handlers
- persist plugin state
- dispose UI resources

Obsidian's load-time guidance says plugins are loaded before users can interact with the app, recommends keeping `onload()` limited to initialization work, and recommends `workspace.onLayoutReady()` for deferred startup code. The same guide warns that `vault.on('create')` fires during vault initialization unless registration is delayed or gated by `layoutReady`. The Plugin API also provides unload-safe registration helpers such as `registerEvent()` and `registerInterval()`. ([Developer Documentation](https://docs.obsidian.md/plugins/guides/load-time "https://docs.obsidian.md/plugins/guides/load-time"))

---

## 7. Vault content contract

### 7.1 Core vault-visible content

Default vault-visible paths:

- `symphony/WORKFLOW.md`
- `symphony/issues/`

The core workflow file and issue notes MUST live in visible vault paths. Hidden-folder issue storage is out of scope for core conformance.

### 7.2 Issue-note format

Each issue is a Markdown file under `vault.issues_path` or its default.

For dispatch eligibility, the plugin SHOULD support an explicit project-related marker in the issue note
frontmatter or body metadata, and MAY infer project relevance from the configured vault path or workflow.
If the marker is present, the issue SHOULD be treated as work that needs to be acted on unless blocked by
workflow policy.

Example:

```markdown
---
id: issue_01HV5M7Z7P5X8E0Q3P6A1N2B3C
identifier: ABC-123
title: Implement OAuth login
state: Todo
priority: 2
labels:
  - backend
blocked_by:
  - identifier: ABC-122
    state: Done
branch_name: feat/abc-123-oauth
url: https://example.invalid/issues/ABC-123
created_at: 2026-03-01T12:00:00Z
updated_at: 2026-03-02T15:00:00Z
---

Implement OAuth login for the main app.

Acceptance criteria:
- Google login
- GitHub login
- tests
```

### 7.3 Mutation rules

- Background body edits MUST use `Vault.process()`.
- Frontmatter edits MUST use `FileManager.processFrontMatter()`.
- Active-editor commands MAY use `Editor` callbacks.
- Vault file deletion or archival MUST use the file manager trash flow rather than permanent delete by default.
- The implementation SHOULD prefer the Vault API over the Adapter API for vault-visible content.

### 7.4 Agent mutation boundary

Agents MUST NOT directly modify vault files through raw filesystem access.

All agent-driven note mutations MUST go through plugin-advertised tools or plugin-owned mutation APIs.

The Vault docs say the Vault API only exposes files visible in the app, recommend `Vault.process()` when changing file content based on current contents, and distinguish trash from permanent deletion. Obsidian's plugin checklist also says not to manage plugin data yourself, not to manually rewrite frontmatter, to prefer `FileManager.processFrontMatter()`, to use `trashFile()` instead of direct delete, and to prefer the Vault API over the Adapter API. ([Developer Documentation](https://docs.obsidian.md/Plugins/Vault "https://docs.obsidian.md/Plugins/Vault"))

---

## 8. Workflow specification

### 8.1 File discovery

Workflow path precedence:

1. plugin setting `workflow_file_path`
2. default `symphony/WORKFLOW.md`

The workflow path is vault-relative and normalized before lookup.

If the file cannot be read, return `missing_workflow_file`.

### 8.2 File format

`WORKFLOW.md` is a Markdown file with optional YAML front matter.

Parsing rules:

- If the file starts with `---`, parse until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, the whole file is the prompt body and config is `{}`.
- Front matter MUST decode to a map/object.
- Prompt body is trimmed.

Returned object:

- `config`
- `prompt_template`

### 8.3 Front matter schema

Top-level keys:

- `vault`
- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `codex`
- `server`

Unknown keys SHOULD be ignored for forward compatibility.

### 8.3.1 `vault` object

Fields:

- `issues_path` (string, vault-relative)
  - default: `symphony/issues`
- `active_states` (list of strings or comma-separated string)
  - default: `Todo`, `In Progress`
- `terminal_states` (list of strings or comma-separated string)
  - default: `Done`, `Closed`, `Cancelled`, `Canceled`, `Duplicate`
- `handoff_states` (list of strings or comma-separated string)
  - optional
  - example: `Human Review`
- `issue_glob` is out of scope for v1
  - all `.md` files under the folder subtree are issue candidates

### 8.3.2 `tracker` object

Optional extension for sync or tool integrations.

Fields:

- `kind`
  - supported extension value in v1: `linear`
- `endpoint`
  - default for linear: `https://api.linear.app/graphql`
- `api_key`
  - literal or `$VAR_NAME`
- `project_slug`
- `active_states`
  - optional sync hint only
- `terminal_states`
  - optional sync hint only

`tracker` is **not required for core dispatch**.

### 8.3.3 `polling` object

- `interval_ms`
  - default: `30000`
  - dynamic reload applies to future ticks

### 8.3.4 `workspace` object

- `root`
  - optional absolute desktop path or `$VAR`
  - discouraged in repo-owned workflow unless truly portable
- `allow_inside_vault`
  - boolean
  - default: false

### 8.3.5 `hooks` object

- `after_create`
- `before_run`
- `after_run`
- `before_remove`
- `timeout_ms`
  - default: `60000`

### 8.3.6 `agent` object

- `max_concurrent_agents`
  - default: `10`
- `max_turns`
  - default: `20`
- `max_retry_backoff_ms`
  - default: `300000`
- `max_concurrent_agents_by_state`
  - default: `{}`

### 8.3.7 `codex` object

- `command`
  - default: `codex app-server`
- `approval_policy`
- `thread_sandbox`
- `turn_sandbox_policy`
- `turn_timeout_ms`
  - default: `3600000`
- `read_timeout_ms`
  - default: `5000`
- `stall_timeout_ms`
  - default: `300000`

Codex-owned config values remain pass-through values validated against the targeted app-server version.

### 8.3.8 `server` object

Optional extension.

- `port`
  - integer
  - loopback bind only unless explicitly configured otherwise

### 8.4 Prompt template contract

Template input variables:

- `issue`
- `attempt`
- `workspace_path`

Strict rendering rules:

- unknown variables fail
- unknown filters fail

Fallback:

- if prompt body is empty, the runtime may use:
  - `You are working on an issue from Obsidian.`

### 8.5 Workflow validation and errors

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error`
- `template_render_error`

Dispatch gating:

- workflow load or parse errors block dispatch
- reconciliation continues
- template render errors fail only the affected run attempt

---

## 9. Configuration specification

### 9.1 Source precedence

Configuration precedence:

1. plugin settings for host-local values
2. workflow file path selection
3. workflow front matter
4. environment indirection via `$VAR_NAME`
5. built-in defaults

Host-local values that plugin settings MAY override include:

- workflow file path
- desktop workspace root
- desktop log root
- auto-start
- HTTP port override

### 9.2 Path resolution semantics

- Vault-relative paths are normalized.
- Desktop filesystem roots may support `~` and `$VAR`.
- Absolute OS paths are required for `desktop_workspace_root` and `desktop_log_root`.
- URIs and arbitrary shell command strings MUST NOT be rewritten as filesystem paths.

### 9.3 Dynamic reload

Dynamic reload is required.

The plugin MUST:

- detect `WORKFLOW.md` changes
- reload config and prompt without restart
- apply updated values to future dispatch, retries, reconciliation, hooks, and launches
- keep the last known good effective config if reload is invalid
- emit an operator-visible error on invalid reload
- defensively revalidate before dispatch in case a vault event was missed

### 9.4 Dispatch preflight validation

Before starting dispatch:

- workflow file loads and parses
- `codex.command` is present
- issue path is valid
- workspace root is valid
- workspace root is outside the vault unless explicitly allowed
- if tracker sync or `linear_graphql` is enabled, tracker credentials are present
- plugin runtime is desktop-capable

### 9.5 Storage rules

- Plugin-owned state MUST use `Plugin.loadData()` / `Plugin.saveData()`.
- The implementation MUST NOT hardcode `.obsidian`.
- If the config directory is needed, use `Vault.configDir`.
- External workspace and log roots are desktop filesystem paths, not vault content roots.

Obsidian's checklist explicitly recommends `loadData()` / `saveData()`, warns against hardcoding `.obsidian`, and recommends `normalizePath()` for user-provided paths. ([Developer Documentation](https://docs.obsidian.md/oo/plugin "https://docs.obsidian.md/oo/plugin"))

---

## 10. Orchestration state machine

### 10.1 Internal orchestration states

- `Unclaimed`
- `Claimed`
- `Running`
- `RetryQueued`
- `Released`

### 10.2 Run-attempt lifecycle

Phases:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

### 10.3 Important nuance

A successful worker exit does **not** mean the issue is permanently done.

Rules:

- a worker may run multiple coding-agent turns on the same live thread
- after each successful turn, the worker re-checks issue state
- if the issue remains active and `agent.max_turns` is not exhausted, the worker starts another turn on the same thread
- the first turn uses the rendered task prompt
- continuation turns send continuation guidance only
- after a normal worker exit, the orchestrator schedules a short continuation retry of about `1000ms`

### 10.4 Recovery and idempotency

- the orchestrator is the only authority that mutates scheduling state
- `claimed` and `running` checks are mandatory before launch
- reconciliation happens before dispatch on every tick
- restart recovery is driven by the vault issue source and filesystem state, not a DB

---

## 11. Polling, scheduling, and reconciliation

### 11.1 Poll loop

At startup:

1. validate config
2. perform startup terminal workspace cleanup
3. schedule an immediate tick
4. continue every `polling.interval_ms`

Tick sequence:

1. reconcile running issues
2. run dispatch preflight validation
3. fetch candidate issues from the vault issue provider
4. sort candidate issues
5. dispatch while slots remain
6. notify dashboard and observers

### 11.2 Event-driven invalidation

Vault events SHOULD coalesce and request an immediate best-effort poll/reconcile cycle when any of these occur under the issue folder or workflow path:

- create
- modify
- rename
- delete

Event-driven invalidation supplements, but does not replace, the fixed poll cadence.

### 11.3 Candidate selection rules

An issue is dispatch-eligible only if all are true:

- it has `id`, `identifier`, `title`, and `state`
- its state is active and not terminal
- it is not already running
- it is not already claimed
- global slots are available
- per-state slots are available
- blocker rule passes:
  - if the issue state is `Todo`, do not dispatch when any blocker is non-terminal

### 11.4 Sorting

1. `priority` ascending
2. `created_at` oldest first
3. `identifier` lexicographic

### 11.5 Concurrency control

Global:

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state:

- use `agent.max_concurrent_agents_by_state[normalized_state]` when present
- otherwise fall back to global limit

### 11.6 Retry and backoff

Retry creation:

- cancel any existing timer for the issue
- store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle

Backoff:

- continuation retry after normal exit: `1000ms`
- failure retry: `min(10000 * 2^(attempt - 1), max_retry_backoff_ms)`

Retry handling:

1. fetch active candidates
2. find the specific issue
3. if missing, release claim
4. if eligible and slots available, dispatch
5. if eligible and slots unavailable, requeue with explicit error
6. if no longer active, release claim

### 11.7 Active-run reconciliation

Part A: stall detection

- if `stall_timeout_ms <= 0`, skip
- otherwise compute elapsed time from last event timestamp or `started_at`
- if exceeded, terminate and queue retry

Part B: issue state refresh

- refresh issue states by ID from the vault issue provider
- if terminal: terminate and clean workspace
- if active: update running entry
- if non-active and non-terminal: terminate without cleanup
- if note missing: terminate and release claim without cleanup

### 11.8 Startup terminal workspace cleanup

At runtime start:

1. fetch issues in terminal states
2. remove corresponding workspaces
3. if fetch fails, log warning and continue startup

---

## 12. Workspace management and safety

### 12.1 Workspace root

Workspace root precedence:

1. plugin setting `desktop_workspace_root`
2. workflow `workspace.root`
3. default:
   - `<system-temp>/obsidian-symphony/<vault-name>/workspaces`

Log root precedence:

1. plugin setting `desktop_log_root`
2. default:
   - `<system-temp>/obsidian-symphony/<vault-name>/logs`

### 12.2 Path rules

- Roots MUST be absolute OS paths.
- Roots MUST be outside the vault unless explicitly allowed.
- Relative external filesystem roots are invalid.
- If an implementation needs the vault OS path, it MUST gate `FileSystemAdapter` use behind an `instanceof` check.

### 12.3 Per-issue workspace path

- `<workspace_root>/<workspace_key>`

### 12.4 Workspace creation and reuse

Algorithm:

1. resolve `workspace_key`
2. compute workspace path
3. enforce root containment
4. ensure directory exists
5. set `created_now`
6. run `after_create` only if newly created

### 12.5 Optional workspace population

The spec does not require built-in VCS logic.

Implementations MAY populate or synchronize a workspace using hooks or implementation-defined code.

### 12.6 Hooks

Supported:

- `after_create`
- `before_run`
- `after_run`
- `before_remove`

Execution contract:

- run with `cwd = workspace_path`
- use host-appropriate local shell
- enforce `hooks.timeout_ms`

Failure semantics:

- `after_create`: fatal
- `before_run`: fatal to attempt
- `after_run`: log and ignore
- `before_remove`: log and ignore

### 12.7 Platform-aware launcher

The shell launcher MUST be platform-aware.

Conforming defaults:

- POSIX: `sh -lc <script>` or stricter equivalent
- Windows: host-appropriate `powershell` or `cmd.exe` launcher

### 12.8 Safety invariants

Invariant 1: agent cwd must equal workspace path.
Invariant 2: workspace path must remain under workspace root.
Invariant 3: workspace key is sanitized.
Invariant 4: agents MUST NOT directly mutate vault files.
Invariant 5: vault writes occur only through plugin-owned APIs or tool bridges.

Obsidian's guidance says not to cast `Vault.adapter` to `FileSystemAdapter` without an `instanceof` check, and desktop-only plugins should still avoid assuming the adapter shape without checking. ([Developer Documentation](https://docs.obsidian.md/oo/plugin "https://docs.obsidian.md/oo/plugin"))

---

## 13. Agent runner protocol

### 13.1 Compatibility profile

The normative contract is:

- message ordering
- timeout handling
- logical fields extracted
- session and turn lifecycle
- usage and rate-limit telemetry handling

Exact JSON field names may vary by compatible app-server version.

### 13.2 Launch contract

Subprocess parameters:

- command: `codex.command`
- invocation: platform-aware shell launch
- working directory: workspace path
- stdout/stderr: separate streams
- framing: line-delimited protocol JSON on stdout

Recommended:

- max line size: 10 MB

### 13.3 Session startup handshake

Conforming startup order:

1. `initialize`
2. `initialized`
3. `thread/start`
4. `turn/start`

For the current Codex app-server docs, the server expects an `initialize` request followed by `initialized` before other requests on that connection, and documents `thread/start` for new threads with related support for `thread/resume` and `thread/fork` when implementations choose to add those extensions. ([OpenAI Developers](https://developers.openai.com/codex/app-server/ "https://developers.openai.com/codex/app-server/"))

### 13.4 Session identifiers

- read `thread_id` from `thread/start`
- read `turn_id` from each `turn/start`
- emit `session_id = "<thread_id>-<turn_id>"`
- reuse the same `thread_id` across continuation turns inside one worker

### 13.5 Streaming turn processing

- read protocol messages from stdout only
- buffer partial lines until newline
- parse only complete stdout lines
- log stderr as diagnostics
- do not attempt protocol parsing on stderr

Completion conditions:

- `turn/completed`
- `turn/failed`
- `turn/cancelled`
- turn timeout
- subprocess exit

### 13.6 Runtime events emitted upstream

Events may include:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`

### 13.7 Approval, tool calls, and user input

Policy is implementation-defined but MUST be documented.

Requirements:

- approval requests must not stall forever
- user-input-required must be resolved, surfaced, or failed
- unsupported tool calls must return a structured failure result and continue

### 13.8 Optional client-side tool extensions

#### A. `linear_graphql`

Unchanged from the original spec and optional.

#### B. `obsidian_issue_get`

Purpose:

- return the normalized current issue record and current note body

Preferred input:

```json
{
  "issueId": "optional-stable-issue-id"
}
```

Behavior:

- if omitted, defaults to the current issue for the active worker
- returns normalized issue fields and note content

#### C. `obsidian_issue_set_frontmatter`

Purpose:

- safely patch issue-note frontmatter

Preferred input:

```json
{
  "issueId": "optional-stable-issue-id",
  "patch": {
    "state": "Human Review",
    "pr_url": "https://example.invalid/pr/123"
  }
}
```

Behavior:

- applies a shallow merge to frontmatter
- executes through plugin-controlled frontmatter mutation
- returns structured success/failure and updated metadata

#### D. `obsidian_issue_append_markdown`

Purpose:

- append an agent update or summary to an issue note

Preferred input:

```json
{
  "issueId": "optional-stable-issue-id",
  "markdown": "\n## Agent update\nImplemented tests.\n"
}
```

Behavior:

- appends via plugin-controlled background content mutation
- returns structured success/failure

These tool bridges preserve the original Symphony boundary that issue writes are typically agent-driven while preventing raw filesystem mutation of vault notes.

### 13.9 Hard failure on user input requirement

If the agent requests user input and no operator-resolution path is configured, fail the run attempt immediately.

### 13.10 Timeouts and error mapping

Recommended categories:

- `codex_not_found`
- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `process_exit`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

### 13.11 Agent runner contract

1. create or reuse workspace
2. run `before_run`
3. build first-turn prompt
4. start session
5. stream events to orchestrator
6. continue turns while active and under turn cap
7. stop session
8. run `after_run`
9. return success or failure

---

## 14. Vault issue provider contract

The vault issue provider replaces the issue tracker client as the core work source.

### 14.1 Required operations

1. `fetch_candidate_issues()`
2. `fetch_issues_by_states(state_names)`
3. `fetch_issue_states_by_ids(issue_ids)`

### 14.2 Discovery semantics

- only Markdown files under `vault.issues_path` are considered
- the provider SHOULD scope traversal to the configured issue folder subtree
- notes outside the configured subtree are ignored
- invalid issue files are logged and excluded from dispatch

### 14.3 Normalization rules

- `labels` -> lowercase strings
- `blocked_by`
  - may be provided as strings, objects, or mixed
  - normalize to blocker refs
- `priority`
  - integer only, else `null`
- `created_at`, `updated_at`
  - parse ISO-8601 timestamps when possible
- `title`
  - frontmatter > first H1 > basename
- `description`
  - note body after front matter

### 14.4 Rename and delete behavior

- rename updates `note_path` in the provider index
- delete removes the issue from the provider index
- missing issue on reconciliation or retry releases the claim

### 14.5 Optional tracker sync

If `tracker.kind` is configured, an implementation MAY mirror state or metadata to and from an external tracker.

Core dispatch still uses the vault issue provider.

Because the Vault API only exposes files visible inside the app, hidden-folder issue stores are not part of core conformance. Obsidian also recommends avoiding broad adapter usage when Vault APIs suffice. ([Developer Documentation](https://docs.obsidian.md/Plugins/Vault "https://docs.obsidian.md/Plugins/Vault"))

---

## 15. Prompt construction and context assembly

### 15.1 Inputs

- `workflow.prompt_template`
- normalized `issue`
- optional `attempt`
- `workspace_path`

### 15.2 Rendering rules

- strict variable checking
- strict filter checking
- nested arrays/maps preserved
- unknown variables or filters fail rendering

### 15.3 Continuation semantics

- first turn: full rendered workflow prompt
- continuation turn: implementation-defined continuation guidance only
- retry after worker failure: full prompt re-render with updated `attempt`

### 15.4 Failure semantics

Prompt rendering failure:

- fails the run attempt immediately
- is treated like any other worker failure for retry purposes

---

## 16. Obsidian UI, commands, settings, and observability

### 16.1 Dashboard view

Symphony MUST register a custom dashboard view, for example view type:

- `symphony-dashboard`

Rules:

- register the view with Obsidian's view registration mechanism
- avoid side effects in the view constructor
- treat the dashboard as an observability/control surface only
- do not make correctness depend on the dashboard

### 16.2 Deferred View compatibility

When accessing leaves of the dashboard type:

- do not assume `leaf.view` is already the concrete custom view
- use `instanceof` checks
- if the view must be addressed directly, reveal the leaf first or explicitly load deferred views sparingly

### 16.3 Dashboard contents

Minimum dashboard contents:

- running sessions
- retry queue
- aggregate token totals
- aggregate runtime totals
- latest rate-limit snapshot
- recent operator-visible errors
- issue-specific drilldown

### 16.4 Settings tab

The plugin SHOULD expose a settings tab with host-local controls such as:

- workflow file path
- desktop workspace root
- desktop log root
- auto-start
- HTTP server enablement and port override
- dashboard preferences

### 16.5 Commands

Recommended commands:

- `Open dashboard`
- `Refresh now`
- `Run current issue`
- `Stop current issue`

Rules:

- command names MUST use sentence case
- command names MUST NOT include the plugin name
- command names MUST NOT include the plugin ID
- v1 SHOULD NOT set default hotkeys
- if a command requires an active Markdown editor or current issue note, use `editorCheckCallback()` or equivalent conditional command handling

### 16.6 Optional UI affordances

The plugin MAY also expose:

- a ribbon action
- a status bar item
- notices for validation or runtime failures

### 16.7 Structured logs

Structured logs MUST include, where applicable:

- `issue_id`
- `issue_identifier`
- `session_id`

Logs MAY be written to:

- a desktop log file
- an in-memory ring buffer for the dashboard
- dev console in development builds only

### 16.8 Runtime snapshot contract

The synchronous runtime snapshot SHOULD include:

- `running`
- `retrying`
- `codex_totals`
- `rate_limits`
- `recent_errors`

### 16.9 Issue-specific debug view

The dashboard SHOULD expose issue-specific details including:

- status
- workspace path
- restart/retry counts
- latest event
- session metadata
- recent events
- log locations
- last error

Obsidian's current docs recommend custom views via the view API, warn against side effects in views, and require Deferred View-safe handling with `instanceof`, `revealLeaf()`, and `loadIfDeferred()` when needed. The plugin checklist also says command labels should not repeat the plugin name or ID, UI text should use sentence case, and default hotkeys should be avoided. Commands that require an editor can use `editorCheckCallback()`. Plugin APIs also expose settings tabs and status bar items. ([Developer Documentation](https://docs.obsidian.md/Plugins/User%2Binterface/Views "https://docs.obsidian.md/Plugins/User%2Binterface/Views"))

---

## 17. Optional HTTP server extension

If implemented:

- the HTTP server is optional
- it MUST bind loopback by default
- it MUST start only on desktop
- it SHOULD start after layout-ready
- port changes may require restart
- README disclosures MUST mention local server/network behavior

Enablement precedence:

1. plugin setting `http_port_override`
2. workflow `server.port`

### 17.1 Endpoints

Recommended baseline:

- `GET /`
- `GET /api/v1/state`
- `GET /api/v1/issues/<issue_identifier>`
- `POST /api/v1/refresh`

Error envelope:

```json
{
  "error": {
    "code": "issue_not_found",
    "message": "..."
  }
}
```

---

## 18. Failure model and recovery strategy

### 18.1 Failure classes

1. `Workflow/Config Failures`
2. `Vault Issue Provider Failures`
3. `Workspace Failures`
4. `Agent Session Failures`
5. `Tracker/HTTP Integration Failures`
6. `Observability/UI Failures`

### 18.2 Recovery behavior

- dispatch validation failure:
  - skip dispatch
  - continue reconciliation
- worker failure:
  - convert to retry
- issue-provider fetch failure:
  - skip dispatch tick
- reconciliation refresh failure:
  - keep workers running
- dashboard or HTTP failure:
  - do not crash orchestrator

### 18.3 Restart recovery

After restart:

- no running sessions are assumed recoverable
- no retry timers are assumed restored
- plugin settings and lightweight persisted state may be restored
- service recovers by:
  - startup terminal cleanup
  - fresh issue indexing
  - fresh polling and dispatch

### 18.4 Operator intervention

Operators can control behavior by:

- editing `WORKFLOW.md`
- editing issue-note state
- running plugin commands
- disabling or restarting the plugin

---

## 19. Security and operational safety

### 19.1 Trust boundary

Each implementation MUST document its approval, sandbox, and execution posture.

### 19.2 Filesystem safety

Mandatory:

- workspace path under configured root
- agent cwd equals per-issue workspace path
- sanitized workspace directory names
- vault note mutations only through plugin-controlled APIs

Recommended:

- run under a dedicated OS user when appropriate
- restrict workspace root permissions
- keep workspace root outside the vault by default

### 19.3 Secret handling

- support `$VAR` indirection
- do not log secrets
- validate presence without printing values

### 19.4 Hook script safety

Hooks are fully trusted configuration.

Requirements:

- run in workspace `cwd`
- timeout enforced
- output truncated in logs
- failures handled according to hook semantics

### 19.5 Tool hardening guidance

Implementations SHOULD evaluate:

- approval and sandbox restrictions
- narrower tracker tool scopes
- reduced available credentials
- reduced available client-side tools
- filesystem and network restrictions
- whether vault note mutation tools should be limited to the current issue note

### 19.6 Release hygiene

The implementation SHOULD:

- avoid client-side telemetry by default
- keep dependencies minimal
- commit a lock file
- disclose network use, external file access, required accounts, and external binaries

Obsidian's current developer policies and review checklist explicitly call out disclosures for network use, external file access, telemetry, accounts, and closed source code; they also recommend minimal dependencies, no client-side telemetry, and a committed lock file. ([Developer Documentation](https://docs.obsidian.md/Developer%2Bpolicies "https://docs.obsidian.md/Developer%2Bpolicies"))

---

## 20. Reference algorithms

### 20.1 Plugin startup

```text
function onload():
  settings = load_plugin_data()
  register_commands()
  register_dashboard_view()
  register_settings_tab()
  register_optional_ribbon_and_status_bar()

  workspace.onLayoutReady(() => {
    start_runtime()
  })
```

### 20.2 Runtime start

```text
function start_runtime():
  state = new_runtime_state()

  validation = validate_dispatch_config()
  if validation not ok:
    emit_operator_visible_error(validation)
    keep_runtime_alive_without_dispatch()

  startup_terminal_workspace_cleanup()
  register_issue_and_workflow_watchers()
  schedule_tick(delay_ms=0)
```

### 20.3 Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)

  validation = validate_dispatch_config()
  if validation not ok:
    emit_operator_visible_error(validation)
    reschedule_tick()
    return

  issues = vault_issue_provider.fetch_candidate_issues()
  if fetch failed:
    log_warning()
    reschedule_tick()
    return

  for issue in sort_for_dispatch(issues):
    if no_available_slots(state):
      break
    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_dashboard()
  reschedule_tick()
```

### 20.4 Vault invalidation

```text
on_issue_or_workflow_event(event):
  mark_pending_reconcile_reason(event)
  request_coalesced_immediate_tick()
```

### 20.5 Worker attempt

```text
function run_agent_attempt(issue, attempt):
  workspace = create_or_reuse_workspace(issue)
  run_hook(before_run)

  session = app_server.start_session(workspace.path)
  turn_number = 1

  while true:
    prompt = build_prompt(issue, attempt, workspace.path, turn_number)
    result = run_turn(session, prompt)

    if result failed:
      stop_session()
      run_hook(after_run)
      fail_worker()

    refreshed = vault_issue_provider.fetch_issue_states_by_ids([issue.id])
    issue = refreshed[0] or issue

    if issue.state is not active:
      break

    if turn_number >= agent.max_turns:
      break

    turn_number += 1

  stop_session()
  run_hook(after_run)
  exit_normal()
```

---

## 21. Test and validation matrix

### 21.1 Core conformance

- workflow path precedence works
- missing workflow returns typed error
- invalid reload keeps last known good config
- plugin-owned state uses `loadData()` / `saveData()`
- vault paths are normalized
- issue-note parsing yields normalized issue objects
- issue index handles create, modify, rename, delete
- watchers do not mis-handle vault bootstrap events
- workspace root containment enforced
- hooks obey timeout and failure semantics
- dispatch sort order works
- blocker rule works
- per-state concurrency works
- continuation retry after normal exit works
- exponential retry backoff works
- reconciliation stops runs for terminal/non-active states
- startup terminal cleanup works
- app-server handshake ordering works
- stdout/stderr separation works
- timeouts and malformed lines handled safely
- token and rate-limit aggregation is correct
- dashboard snapshot reflects orchestrator state
- operator-visible failures are surfaced

### 21.2 Obsidian-specific conformance

- manifest includes required fields
- manifest `isDesktopOnly` is true
- `id` does not contain `obsidian`
- no default hotkeys are shipped
- command labels omit plugin name and plugin ID
- heavy startup occurs after `workspace.onLayoutReady()`
- event listeners are registered unload-safely
- dashboard works with Deferred Views
- frontmatter writes use `processFrontMatter`
- background content writes use `Vault.process`
- vault deletions use trash flow
- outbound plugin HTTP uses `requestUrl`
- `FileSystemAdapter` usage is guarded with `instanceof`
- no hardcoded `.obsidian` paths are used

### 21.3 Extension conformance

If tracker sync is implemented:

- `linear_graphql` uses configured auth
- sync failures do not crash orchestration

If HTTP server is implemented:

- loopback bind works
- endpoints return expected shapes
- refresh trigger is best-effort and coalesced

---

## 22. Implementation checklist

### 22.1 Required for conformance

- desktop-only Obsidian plugin packaging
- workflow loader with YAML front matter
- typed config layer
- vault issue provider
- single-authority orchestrator state
- per-issue workspaces
- workspace hooks
- strict prompt rendering
- agent subprocess client
- continuation turns and continuation retries
- exponential retry queue
- reconciliation and startup cleanup
- structured logs
- dashboard view
- operator-visible failures
- safe vault mutation path
- plugin lifecycle compliance

### 22.2 Recommended extensions

- `obsidian_issue_*` tool bridges
- `linear_graphql` tool
- local HTTP API
- tracker sync
- persisted workspace-key mapping
- per-issue log viewer
- richer issue creation commands

### 22.3 Operational validation before production

- validate on a real desktop vault
- verify load/unload behavior
- verify issue-folder events after layout-ready
- verify workspace path safety
- verify agent approval and sandbox posture
- verify documentation/disclosures

---

## 23. Definition of done

Symphony is conformant when:

- it behaves as an Obsidian desktop plugin first
- it preserves the original Symphony orchestration semantics
- it safely treats vault Markdown notes as issues
- it runs coding agents only in external per-issue workspaces
- it reloads workflow changes without restart
- it remains operable and debuggable through the dashboard and logs
- it documents its trust, safety, and external-access posture clearly

([Developer Documentation](https://docs.obsidian.md/Reference/Manifest "https://docs.obsidian.md/Reference/Manifest"))
