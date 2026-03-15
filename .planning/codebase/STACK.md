# Technology Stack

## Runtime

| Component | Version | Notes |
|-----------|---------|-------|
| Elixir | ~> 1.19 (1.19.5) | Managed via `mise` |
| Erlang/OTP | 28 | Required minimum |
| BEAM VM | OTP-28 | Single-node deployment |

## Frameworks

| Framework | Version | Purpose |
|-----------|---------|---------|
| Phoenix | ~> 1.8.0 | Web dashboard & API |
| Phoenix LiveView | ~> 1.1.0 | Real-time observability dashboard |
| Ecto | ~> 3.13 | Config schema validation (no database) |
| Bandit | ~> 1.8 | HTTP server adapter |

## Production Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `req` | ~> 0.5 | HTTP client (Linear GraphQL API) |
| `jason` | ~> 1.4 | JSON encoding/decoding |
| `yaml_elixir` | ~> 2.12 | WORKFLOW.md YAML front matter parsing |
| `solid` | ~> 1.2 | Liquid template engine for prompts |
| `phoenix_html` | ~> 4.2 | HTML helpers |

## Dev/Test Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `credo` | ~> 1.7 | Code style linter |
| `dialyxir` | ~> 1.4 | Static type analysis |
| `floki` | >= 0.30.0 | HTML parsing (tests) |
| `lazy_html` | >= 0.1.0 | HTML utilities (tests) |

## Build & Tooling

- **Build tool:** Mix
- **Output:** Escript binary at `bin/symphony`
- **Entry point:** `SymphonyElixir.CLI.main/1`
- **Version manager:** mise (`mise.toml`)
- **Formatter:** `.formatter.exs` (200 char line length)

## Quality Gate (`make all`)

1. `mix format --check-formatted`
2. `mix specs.check` (100% public function @spec coverage)
3. `mix credo --strict`
4. `mix test --cover` (100% threshold, 22 modules exempted)
5. `mix dialyzer`
