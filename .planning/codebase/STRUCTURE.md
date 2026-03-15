# Directory Structure

## Source Layout

```
elixir/
├── lib/
│   ├── symphony_elixir.ex                    # Application module
│   ├── symphony_elixir/
│   │   ├── application.ex                    # OTP Application, supervision tree
│   │   ├── orchestrator.ex                   # Core GenServer: poll, dispatch, retry (1655 L)
│   │   ├── agent_runner.ex                   # Single-issue executor (229 L)
│   │   ├── cli.ex                            # Escript entrypoint (192 L)
│   │   ├── config.ex                         # Runtime config access (154 L)
│   │   ├── config/
│   │   │   └── schema.ex                     # Ecto-based config validation (557 L)
│   │   ├── workflow.ex                       # WORKFLOW.md loader (YAML + Liquid)
│   │   ├── workflow_store.ex                 # GenServer: config cache, hot-reload
│   │   ├── workspace.ex                      # Per-issue workspace lifecycle (484 L)
│   │   ├── tracker.ex                        # Behaviour: issue tracker adapter
│   │   ├── tracker/
│   │   │   └── memory.ex                     # In-memory tracker (testing)
│   │   ├── linear/
│   │   │   ├── client.ex                     # GraphQL client (587 L)
│   │   │   ├── adapter.ex                    # Linear tracker implementation
│   │   │   └── issue.ex                      # Normalized issue struct
│   │   ├── codex/
│   │   │   ├── app_server.ex                 # JSON-RPC 2.0 client (1088 L)
│   │   │   └── dynamic_tool.ex               # Client-side tool execution
│   │   ├── http_server.ex                    # Phoenix endpoint startup (89 L)
│   │   ├── status_dashboard.ex               # Terminal UI GenServer (1952 L)
│   │   ├── log_file.ex                       # OTP rotating disk log
│   │   ├── path_safety.ex                    # Path canonicalization, symlink safety
│   │   ├── prompt_builder.ex                 # Liquid template prompt rendering
│   │   ├── ssh.ex                            # SSH command execution
│   │   └── specs_check.ex                    # @spec enforcement analyzer
│   │
│   ├── symphony_elixir_web/
│   │   ├── router.ex                         # Phoenix routes
│   │   ├── endpoint.ex                       # Phoenix endpoint config
│   │   ├── observability_pubsub.ex           # PubSub for dashboard updates
│   │   ├── presenter.ex                      # State → view projections
│   │   ├── controllers/
│   │   │   ├── observability_api_controller.ex
│   │   │   └── static_asset_controller.ex
│   │   ├── live/
│   │   │   └── dashboard_live.ex             # LiveView dashboard
│   │   ├── components/
│   │   │   └── layouts.ex
│   │   ├── static_assets.ex                  # Asset bundling
│   │   ├── error_html.ex
│   │   └── error_json.ex
│   │
│   └── mix/tasks/
│       ├── specs_check.ex                    # mix specs.check
│       ├── pr_body_check.ex                  # mix pr_body.check
│       └── workspace_before_remove.ex        # mix workspace.before_remove
│
├── test/
│   ├── test_helper.exs
│   ├── support/
│   │   ├── test_support.exs                  # Shared macros, workflow helpers
│   │   └── snapshot_support.exs              # Snapshot assertion utilities
│   ├── symphony_elixir/
│   │   ├── orchestrator_status_test.exs      # Orchestrator state management
│   │   ├── orchestrator_helpers_test.exs     # Dispatch/sort/revalidate helpers
│   │   ├── agent_runner_test.exs
│   │   ├── cli_test.exs
│   │   ├── config_test.exs
│   │   ├── config_schema_test.exs
│   │   ├── core_test.exs                     # Integration tests
│   │   ├── workflow_test.exs
│   │   ├── workflow_store_test.exs
│   │   ├── workspace_and_config_test.exs
│   │   ├── workspace_validation_test.exs
│   │   ├── linear_client_test.exs
│   │   ├── linear_adapter_test.exs
│   │   ├── app_server_test.exs               # Codex integration (1333 L)
│   │   ├── dynamic_tool_test.exs
│   │   ├── status_dashboard_test.exs
│   │   ├── status_dashboard_snapshot_test.exs
│   │   ├── presenter_test.exs
│   │   ├── web_modules_test.exs
│   │   ├── extensions_test.exs               # Phoenix ConnTest/LiveViewTest
│   │   ├── observability_pubsub_test.exs
│   │   ├── log_file_test.exs
│   │   ├── log_file_configure_test.exs
│   │   ├── path_safety_test.exs
│   │   ├── prompt_builder_test.exs
│   │   ├── ssh_test.exs
│   │   ├── specs_check_test.exs
│   │   └── live_e2e_test.exs                 # Real Linear/Codex E2E
│   ├── mix/tasks/
│   │   ├── pr_body_check_test.exs
│   │   ├── specs_check_task_test.exs
│   │   └── workspace_before_remove_test.exs
│   └── fixtures/                             # Snapshot test fixtures
│
├── docs/
│   ├── logging.md
│   └── token_accounting.md
├── mix.exs
├── Makefile
├── AGENTS.md
├── README.md
└── WORKFLOW.md                               # Runtime configuration
```

## Module Count

- **Core lib modules:** 22
- **Web modules:** 11
- **Mix tasks:** 3
- **Test files:** 30+
