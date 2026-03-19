defmodule SymphonyElixir.HarnessBootstrapTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HarnessBootstrap

  test "creates minimal harness files for an under-instrumented repo" do
    workspace = Path.join(System.tmp_dir!(), "symphony-bootstrap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, result} = HarnessBootstrap.ensure(workspace)

    assert "AGENTS.md" in result.changed
    assert File.exists?(Path.join(workspace, "AGENTS.md"))
    assert File.exists?(Path.join([workspace, ".codex", "README.md"]))
    assert File.exists?(Path.join([workspace, ".claude", "README.md"]))
    assert File.exists?(Path.join([workspace, ".codex", "skills", "linear", "SKILL.md"]))
  end

  test "does not overwrite existing harness files" do
    workspace = Path.join(System.tmp_dir!(), "symphony-bootstrap-existing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([workspace, ".codex", "skills", "linear"]))
    File.write!(Path.join(workspace, "AGENTS.md"), "custom")
    File.write!(Path.join([workspace, ".codex", "skills", "linear", "SKILL.md"]), "custom-skill")

    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, result} = HarnessBootstrap.ensure(workspace)
    assert File.read!(Path.join(workspace, "AGENTS.md")) == "custom"
    assert File.read!(Path.join([workspace, ".codex", "skills", "linear", "SKILL.md"])) == "custom-skill"
    refute "AGENTS.md" in result.changed
  end

  test "detect mode reports gaps without writing files" do
    workspace = Path.join(System.tmp_dir!(), "symphony-bootstrap-detect-#{System.unique_integer([:positive])}")
    workflow_path = Path.join(workspace, "WORKFLOW.md")
    File.mkdir_p!(workspace)

    previous = SymphonyElixir.Workflow.workflow_file_path()

    write_workflow_file!(workflow_path, harness_bootstrap_mode: "detect")
    SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)

    on_exit(fn ->
      SymphonyElixir.Workflow.set_workflow_file_path(previous)
      File.rm_rf(workspace)
    end)

    assert {:ok, result} = HarnessBootstrap.ensure(workspace)
    assert result.mode == "detect"
    assert result.changed == []
    refute File.exists?(Path.join(workspace, "AGENTS.md"))
  end
end
