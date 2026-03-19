defmodule SymphonyElixir.HarnessBootstrap do
  @moduledoc """
  Adds a minimal agent harness to under-instrumented repositories before execution.
  """

  require Logger

  alias SymphonyElixir.Config

  @spec ensure(Path.t()) :: {:ok, map()} | {:error, term()}
  def ensure(workspace) when is_binary(workspace) do
    config = Config.settings!().harness.bootstrap

    cond do
      config.enabled != true ->
        {:ok, %{enabled: false, changed: [], detected: detect(workspace)}}

      config.mode not in ["core", "full"] ->
        {:ok, %{enabled: true, mode: config.mode, changed: [], detected: detect(workspace)}}

      true ->
        detected = detect(workspace)

        with :ok <- maybe_create_agents_md(workspace, detected),
             :ok <- maybe_create_codex_readme(workspace, detected),
             :ok <- maybe_create_claude_readme(workspace, detected),
             :ok <- maybe_create_linear_skill(workspace, detected) do
          refreshed = detect(workspace)
          changed = changed_files(detected, refreshed)

          Logger.info(
            "Harness bootstrap completed workspace=#{workspace} mode=#{config.mode} changed=#{inspect(changed)}"
          )

          {:ok, %{enabled: true, mode: config.mode, changed: changed, detected: refreshed}}
        end
    end
  end

  @spec detect(Path.t()) :: map()
  def detect(workspace) when is_binary(workspace) do
    %{
      has_agents_md: File.exists?(Path.join(workspace, "AGENTS.md")),
      has_codex_dir: File.dir?(Path.join(workspace, ".codex")),
      has_codex_readme: File.exists?(Path.join([workspace, ".codex", "README.md"])),
      has_claude_dir: File.dir?(Path.join(workspace, ".claude")),
      has_claude_readme: File.exists?(Path.join([workspace, ".claude", "README.md"])),
      has_linear_skill: File.exists?(Path.join([workspace, ".codex", "skills", "linear", "SKILL.md"])),
      has_validation_hint: has_validation_hint?(workspace),
      has_review_contract: has_review_contract?(workspace)
    }
  end

  defp maybe_create_agents_md(_workspace, %{has_agents_md: true}), do: :ok

  defp maybe_create_agents_md(workspace, detected) do
    content = agents_md_content(workspace, detected)
    File.write(Path.join(workspace, "AGENTS.md"), content)
  end

  defp maybe_create_codex_readme(_workspace, %{has_codex_readme: true}), do: :ok

  defp maybe_create_codex_readme(workspace, _detected) do
    codex_dir = Path.join(workspace, ".codex")
    :ok = File.mkdir_p(codex_dir)

    File.write(
      Path.join(codex_dir, "README.md"),
      """
      # Symphony Bootstrap

      This repository was bootstrapped with a minimal Codex harness by Symphony.

      - Keep repository-specific guidance in `AGENTS.md`.
      - Add reusable helper skills under `.codex/skills/`.
      - Prefer deterministic validation commands before handoff.
      """
    )
  end

  defp maybe_create_claude_readme(_workspace, %{has_claude_readme: true}), do: :ok

  defp maybe_create_claude_readme(workspace, _detected) do
    claude_dir = Path.join(workspace, ".claude")
    :ok = File.mkdir_p(claude_dir)

    File.write(
      Path.join(claude_dir, "README.md"),
      """
      # Symphony Bootstrap

      This repository was bootstrapped with a minimal agent harness by Symphony.

      - Keep shared agent guidance in `AGENTS.md`.
      - Add reusable Claude-oriented skills under `.claude/skills/` when needed.
      - Keep secrets in environment variables, not in committed harness files.
      """
    )
  end

  defp maybe_create_linear_skill(workspace, %{has_codex_dir: false}) do
    codex_skill_dir = Path.join([workspace, ".codex", "skills", "linear"])
    :ok = File.mkdir_p(codex_skill_dir)
    File.write(Path.join(codex_skill_dir, "SKILL.md"), linear_skill_content())
  end

  defp maybe_create_linear_skill(workspace, _detected) do
    skill_path = Path.join([workspace, ".codex", "skills", "linear", "SKILL.md"])

    if File.exists?(skill_path) do
      :ok
    else
      :ok = File.mkdir_p(Path.dirname(skill_path))
      File.write(skill_path, linear_skill_content())
    end
  end

  defp linear_skill_content do
    """
    ---
    name: linear
    description: Use the typed Symphony Linear workflow tools before falling back to raw GraphQL.
    allowed-tools: Read
    ---

    Prefer `linear_workflow` for issue context, workpad updates, state transitions, PR links, and follow-up issue creation.
    Use `linear_graphql` only when the typed workflow tool does not support the required action.
    """
  end

  defp agents_md_content(workspace, detected) do
    validation_line =
      case recommended_validation(workspace) do
        nil -> "- Validation: add at least one deterministic repo validation command."
        command -> "- Validation: default to `#{command}` for proof before handoff."
      end

    review_line =
      if detected.has_review_contract do
        "- Review contract: existing PR/review metadata detected; preserve it."
      else
        "- Review contract: add a PR template or equivalent reviewer checklist if this repo uses PR handoff."
      end

    """
    # Repository Agent Guide

    Symphony generated this minimal agent harness because the repository was missing at least one core agent foundation file.

    - Work inside the checked-out repository only.
    - Keep changes scoped to the assigned task.
    #{validation_line}
    #{review_line}
    - Keep reusable agent guidance under `.codex/`.
    """
  end

  defp has_validation_hint?(workspace) do
    Enum.any?(
      [
        "Makefile",
        "mix.exs",
        "package.json",
        "cargo.toml",
        "Cargo.toml",
        "pytest.ini",
        "go.mod"
      ],
      fn path -> File.exists?(Path.join(workspace, path)) end
    )
  end

  defp has_review_contract?(workspace) do
    File.exists?(Path.join([workspace, ".github", "pull_request_template.md"])) or
      File.exists?(Path.join([workspace, ".gitlab", "merge_request_templates"]))
  end

  defp recommended_validation(workspace) do
    cond do
      File.exists?(Path.join(workspace, "mix.exs")) -> "mix test"
      File.exists?(Path.join(workspace, "package.json")) -> "npm test"
      File.exists?(Path.join(workspace, "Cargo.toml")) -> "cargo test"
      File.exists?(Path.join(workspace, "go.mod")) -> "go test ./..."
      File.exists?(Path.join(workspace, "pytest.ini")) -> "pytest"
      true -> nil
    end
  end

  defp changed_files(before_detected, after_detected) do
    []
    |> maybe_add_changed("AGENTS.md", before_detected.has_agents_md, after_detected.has_agents_md)
    |> maybe_add_changed(".codex/README.md", before_detected.has_codex_readme, after_detected.has_codex_readme)
    |> maybe_add_changed(".claude/README.md", before_detected.has_claude_readme, after_detected.has_claude_readme)
    |> maybe_add_changed(".codex/skills/linear/SKILL.md", before_detected.has_linear_skill, after_detected.has_linear_skill)
  end

  defp maybe_add_changed(acc, _path, before_value, after_value) when before_value == after_value, do: acc
  defp maybe_add_changed(acc, path, _before_value, _after_value), do: acc ++ [path]
end
