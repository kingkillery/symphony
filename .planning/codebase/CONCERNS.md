# Concerns

## Test Coverage Gaps

22 modules excluded from 100% coverage threshold. Largest untested modules:
- **StatusDashboard** (1952 L) — terminal rendering + state aggregation
- **Orchestrator** (1655 L) — dispatch, retry, reconciliation
- **AppServer** (1088 L) — JSON-RPC protocol, port management
- **Linear.Client** (587 L) — GraphQL, pagination
- **Workspace** (484 L) — path safety, hooks, SSH

Recent work added `_for_test` helper tests and injectable dependency tests, but full module coverage requires production code changes (injection points).

## Security

### Strengths
- Path canonicalization with symlink resolution (`PathSafety`)
- Shell escaping for remote commands
- API token indirection via `$VAR` syntax

### Concerns
- **Hook command injection:** `after_create`, `before_run`, `after_run`, `before_remove` hooks are arbitrary shell scripts from WORKFLOW.md config with no sandboxing beyond cwd
- **SSH codex.command:** Passed to shell without escaping — trusts config origin
- **TOCTOU:** Workspace path validated then used non-atomically
- **Remote path validation:** Only checks null bytes/newlines, no canonicalization on remote hosts
- **API token in logs:** Error payloads truncated to 1KB but could contain partial sensitive data

## Concurrency Risks

1. **Worker host capacity race:** Slot check and dispatch are not atomic — could exceed `max_concurrent_agents_per_host`
2. **Retry timer loss:** If `Process.send_after` fails after cancelling old timer, retry is lost
3. **Stall detection:** Based on monotonic clock timeout; doesn't validate cause of stall
4. **State resurrection:** If issue terminates between running map read and write, could resurrect dead entry

## Error Handling Gaps

- **Linear rate limits:** 429 responses logged but no backoff adjustment
- **No circuit breaker:** Repeated API failures don't slow polling
- **Hook failures:** `before_run`/`after_run` failures logged but don't abort
- **Agent exit classification:** No distinction between timeout, OOM, permission denied, or crash
- **Port leak:** If SSH connection drops, no automatic recovery mechanism

## Hardcoded Values

| Value | Location | Risk |
|-------|----------|------|
| 50 issue page size | Linear.Client | Unscalable for large projects |
| 1MB port line buffer | AppServer | Memory spike on large Codex output |
| 1KB error log truncation | Linear.Client | Loss of debugging info |
| 1s continuation retry | Orchestrator | No backoff |
| 16ms render interval | StatusDashboard | Flicker on slow terminals |

## Production Readiness

- **In-memory state:** All runtime state (running, claimed, retry queue) lost on restart
- **No graceful shutdown:** Terminating orchestrator kills active agents immediately
- **No metrics export:** Only in-memory dashboard (no Prometheus/StatsD)
- **No trace IDs:** Cannot correlate across issue lifecycle
- **No alerts:** Stalls, rate limits, cleanup failures not surfaced to operators

## Configuration Validation Gaps

- Poll interval minimum not enforced (can be 1ms)
- Per-state concurrency limits not validated against global limit
- Approval policy map structure not validated beyond "is map"
- Active states list can be empty (disables all dispatch)
- Workspace root accepts relative paths (ambiguous if cwd changes)

## Dependency Risks

- Phoenix ~> 1.8.0 lock is strict; 1.9+ security patches won't auto-apply
- `solid` (Liquid engine) used for prompt templates — injection risk if prompts contain user input
- No explicit Codex version dependency (protocol coupling undocumented)
- No `mix audit` in CI for vulnerability scanning
