# Symphony

Symphony is an Obsidian desktop plugin for vault-driven issue orchestration.

## Workspace connection

This plugin is intended to be edited from the Symphony PM repo at:

`C:\dev\Desktop-Projects\Symphony-PM\symphony`

If you want a direct mirror inside that repo, create a junction at:

`C:\dev\Desktop-Projects\Symphony-PM\symphony\obsidian-plugin`

that points back to this folder:

`C:\dev\Desktop-Projects\Obsidian Plugins\plugins\symphony`

This directory currently contains:

- a desktop-only Obsidian plugin manifest
- TypeScript build and bundle wiring
- a live dashboard that indexes and dispatches eligible issue notes
- retry-aware command and settings wiring for an external execution layer
- a `SPEC.md` file containing the working product specification

## Vault install

Use the repo-owned installer to deploy the built plugin into the managed vault set:

```bash
npm run build
npm run install:vaults
```

The installer:

- copies `manifest.json`, `main.js`, and `styles.css` into each managed vault
- ensures `symphony` is listed in `.obsidian/community-plugins.json`
- writes plugin `data.json` using Obsidian's wrapped `{ settings, runtime }` structure
- stamps each vault with its configured `symphonyInstanceId`
- preserves existing runtime state when reinstalling

## Execution layer

Symphony now watches the configured issue folder, identifies project-related notes, and can
dispatch eligible issues through a configurable runner command. Failed or interrupted runs are
persisted and retried after restart when auto-dispatch is enabled.

Execution policy can be defined in `WORKFLOW.md` frontmatter and then overridden locally in the
plugin settings when a machine-specific value is needed.

Supported runtime keys in `WORKFLOW.md`:

- `obsidian_plugin.runner_command_template`
- `obsidian_plugin.auto_dispatch_project_tasks`
- `obsidian_plugin.max_concurrent_runs`
- `obsidian_plugin.runner_timeout_ms`
- `obsidian_plugin.issue_folder_path`
- `obsidian_plugin.project_related_marker`
- `obsidian_plugin.desktop_workspace_root`
- `obsidian_plugin.desktop_log_root`

Local settings still exist for:

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

## Commands

The plugin now exposes command-palette actions for vault-native task intake:

- `Symphony: Create Symphony task`
- `Symphony: Assign current note to Symphony`
- `Symphony: Run current issue`
- `Symphony: Stop current issue`

Use `Symphony instance ID` in plugin settings to stamp created or assigned notes with the
vault's Symphony instance identifier.

What is not implemented yet:

- full workflow validation and templated prompt rendering
- tracker writeback beyond note frontmatter
- richer orchestration policies than direct shell dispatch

Use this plugin alongside the product specification in `SPEC.md`.
