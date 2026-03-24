# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Obsidian plugin connection

The Obsidian plugin scaffold lives at:

`C:\dev\Desktop-Projects\Obsidian Plugins\plugins\symphony`

Use that folder as the active plugin workspace when iterating on the Obsidian integration. The
fastest workflow is to keep this repo as the specification/source-of-truth and edit the plugin
workspace directly, or wire a symlink/junction from this repo into that directory if you want a
single working copy.

Suggested Windows junction command:

```powershell
New-Item -ItemType Junction `
  -Path "C:\dev\Desktop-Projects\Symphony-PM\symphony\obsidian-plugin" `
  -Target "C:\dev\Desktop-Projects\Obsidian Plugins\plugins\symphony"
```

After that, you can open `C:\dev\Desktop-Projects\Symphony-PM\symphony\obsidian-plugin` as the
plugin mirror without having to remember the longer path.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. The Elixir reference now also includes a
self-contained Docker image and Compose file under [elixir/](elixir/). You can also ask your
favorite coding agent to help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
