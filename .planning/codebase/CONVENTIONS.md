# Code Conventions

## Module Structure

```elixir
defmodule SymphonyElixir.ModuleName do
  @moduledoc """Short description."""

  require Logger
  use GenServer  # or other behaviour

  alias SymphonyElixir.{Module1, Module2}

  @constant_name value

  # Public API (with @spec)
  @spec public_func(arg_type) :: return_type
  def public_func(arg), do: ...

  # Nested structs (if needed)
  defmodule State do
    defstruct [:field]
  end

  # Private helpers
  defp helper_func, do: ...
end
```

## @spec Requirement

- **All** public `def` functions must have an adjacent `@spec` — enforced by `mix specs.check`
- `defp` specs are optional
- `@impl` callback implementations are exempt
- Validated in CI: zero tolerance

## Naming

- **Modules:** PascalCase under `SymphonyElixir.*` (domain: `Linear.*`, `Codex.*`)
- **Functions:** snake_case (`fetch_candidate_issues`, `create_for_issue`)
- **Test helpers:** `_for_test` suffix for exported internal logic
- **Constants:** module attributes (`@handler_id`, `@poll_interval_ms`)
- **Bang functions:** `!` suffix for raising variants (`settings!`, `write_workflow_file!`)

## Error Handling

- Primary pattern: `{:ok, result} | {:error, reason}`
- Tagged error tuples: `{:error, {:invalid_workspace_cwd, :workspace_root, path}}`
- `with` chains for multi-step error propagation
- `rescue` used selectively in critical paths (workspace, port cleanup)

## Dependency Injection (4 Patterns)

1. **Keyword opts:** `execute(tool, args, opts \\ [])` with `Keyword.get(opts, :linear_client, &Client.graphql/3)`
2. **Application env:** `Application.get_env(:symphony_elixir, :linear_client_module, Client)`
3. **`_for_test` exports:** `normalize_issue_for_test/1`, `reconcile_issue_states_for_test/2`
4. **`deps` map:** CLI `evaluate/2` accepts injectable function map

## Logging

- `require Logger` at module top
- Structured `key=value` pairs: `issue_id=#{id} session_id=#{sid}`
- Required context: `issue_id`, `issue_identifier` for issue work; `session_id` for Codex
- Deterministic wording: `completed`, `failed`, `retrying`
- See `docs/logging.md` for full conventions

## Configuration

- All config through `SymphonyElixir.Config` module (not ad-hoc env reads)
- Source: WORKFLOW.md YAML front matter
- Validated via `Config.Schema` (Ecto-based)
- Hot-reloadable via `WorkflowStore` GenServer

## Code Style

- Line length: 200 characters (`.formatter.exs`)
- Standard Elixir formatter
- Structs over maps for fixed shapes
- Alphabetical aliases
- `@moduledoc` required on all modules (use `false` for internal)
