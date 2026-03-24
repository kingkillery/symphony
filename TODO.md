# TODO

## Obsidian plugin backlog

1. [#4](https://github.com/kingkillery/symphony/issues/4) Add workflow validation and prompt rendering for the Obsidian plugin
   Current gap: [workflow-config.ts](/C:/dev/Desktop-Projects/Symphony-PM/symphony/obsidian-plugin/src/workflow-config.ts) only does lightweight override parsing.

2. [#5](https://github.com/kingkillery/symphony/issues/5) Add tracker sync and richer tracker writeback for the Obsidian plugin
   Current gap: the plugin only writes local note frontmatter and has no tracker adapter bridge yet.

3. [#6](https://github.com/kingkillery/symphony/issues/6) Expand the Obsidian execution layer beyond direct shell dispatch
   Current gap: [execution-layer.ts](/C:/dev/Desktop-Projects/Symphony-PM/symphony/obsidian-plugin/src/execution-layer.ts) is still a direct subprocess runner.
