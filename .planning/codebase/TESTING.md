# Testing

## Framework

- **ExUnit** (Elixir standard)
- `async: true` default; `async: false` when modifying Application env or global state
- Test files mirror source: `test/symphony_elixir/module_test.exs` ↔ `lib/symphony_elixir/module.ex`

## Coverage Enforcement

- **Threshold:** 100% (configured in `mix.exs`)
- **22 modules exempted** via `ignore_modules` (Orchestrator, AppServer, Workspace, web modules, etc.)
- Run: `mix test --cover`

## Test Support (`test/support/test_support.exs`)

Macro-based setup providing:
- Auto-aliases for all core modules
- `write_workflow_file!(path, overrides)` — generates WORKFLOW.md with defaults
- `restore_env(key, value)` — environment cleanup
- `stop_default_http_server()` — HTTP cleanup
- Temp directory creation with `on_exit` cleanup

Usage: `use SymphonyElixir.TestSupport`

## Snapshot Testing (`test/support/snapshot_support.exs`)

- `assert_snapshot!(path, content)` — fixture-based assertions
- `assert_dashboard_snapshot!(name, ansi_content)` — dashboard rendering
- Update mode: `UPDATE_SNAPSHOTS=1 mix test`
- Fixtures in `test/fixtures/`

## Mock Patterns

### Keyword Option Injection
```elixir
DynamicTool.execute("linear_graphql", args,
  linear_client: fn query, vars, opts -> {:ok, %{"data" => result}} end
)
```

### Application Env Module Swap
```elixir
setup do
  Application.put_env(:symphony_elixir, :linear_client_module, FakeClient)
  on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_module) end)
end
```

### `_for_test` Helper Functions
```elixir
# Direct unit testing of internal logic without side effects
Orchestrator.should_dispatch_issue_for_test(issue, state)
Client.normalize_issue_for_test(issue_map)
```

### FakePort Pattern (AppServer tests)
Spawns bash processes emitting scripted JSON-RPC 2.0 responses for Codex protocol testing.

### `deps` Map (CLI tests)
```elixir
deps = %{
  file_regular?: fn _path -> true end,
  set_workflow_file_path: fn _path -> :ok end,
  ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
}
CLI.evaluate(args, deps)
```

## Test Isolation

- Temp files cleaned via `on_exit(fn -> File.rm_rf!(dir) end)`
- Application env saved/restored
- Process dictionary isolated per test
- GenServers stopped explicitly

## E2E Tests

- `test/symphony_elixir/live_e2e_test.exs`
- Requires real Linear credentials and Codex
- Run: `SYMPHONY_RUN_LIVE_E2E=1 mix test test/symphony_elixir/live_e2e_test.exs`

## Quality Gate

```bash
make all  # = make ci
# Runs: setup → build → fmt-check → lint → coverage → dialyzer
```
