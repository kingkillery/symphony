# Symphony

Symphony is an Obsidian desktop plugin scaffold for vault-driven issue orchestration.

## Workspace connection

This plugin is intended to be edited from the Symphony PM repo at:

`C:\dev\Desktop-Projects\Symphony-PM\symphony`

If you want a direct mirror inside that repo, create a junction at:

`C:\dev\Desktop-Projects\Symphony-PM\symphony\obsidian-plugin`

that points back to this folder:

`C:\dev\Desktop-Projects\Obsidian Plugins\plugins\symphony`

This directory currently contains:

- a desktop-only Obsidian plugin manifest
- TypeScript build scaffolding
- a live dashboard that indexes and dispatches eligible issue notes
- command and settings wiring for a configurable external execution layer
- a `SPEC.md` file containing the working product specification

## Execution layer

Symphony now watches the configured issue folder, identifies project-related notes, and can
dispatch eligible issues through a configurable runner command.

Configure the plugin settings with:

- `Issue folder path`
- `Project-related marker`
- `Runner command template`
- `Auto-dispatch project tasks`
- `Max concurrent runs`

Supported runner template placeholders:

- `{{issue_path}}`
- `{{issue_title}}`
- `{{vault_path}}`
- `{{workspace_root}}`
- `{{log_root}}`

What is not implemented yet:

- workflow loading and validation
- workflow-driven runner templating
- retries, reconciliation, and runtime persistence

Use this scaffold as the starting point for implementing the specification in `SPEC.md`.
