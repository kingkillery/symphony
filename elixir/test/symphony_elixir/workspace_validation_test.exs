defmodule SymphonyElixir.WorkspaceValidationTest do
  @moduledoc """
  Tests for Workspace error paths: remote validation, parse_remote_workspace_output,
  and path canonicalization edge cases.
  """

  use SymphonyElixir.TestSupport

  # -- safe_identifier and workspace path edge cases --

  test "workspace path with special characters in identifier is sanitized" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-ws-special-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      # Characters like /, \n, etc. are replaced by safe_identifier
      assert {:ok, workspace} = Workspace.create_for_issue("IS/SUE\n123")
      assert Path.basename(workspace) == "IS_SUE_123"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creation with nil identifier uses fallback" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-ws-nil-id-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue(nil)
      assert Path.basename(workspace) == "issue"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace remove returns error for path that equals root" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-ws-root-eq-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_equals_root, _, _}, ""} = Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace remove returns error for path outside root" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-ws-outside-#{System.unique_integer([:positive])}"
      )

    outside_dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-ws-other-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_dir)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_outside_root, _, _}, ""} = Workspace.remove(outside_dir)
    after
      File.rm_rf(workspace_root)
      File.rm_rf(outside_dir)
    end
  end

  test "workspace creation with struct issue extracts identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-ws-struct-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %{id: "uuid-1", identifier: "PROJ-42"}
      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert Path.basename(workspace) == "PROJ-42"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace remove_issue_workspaces handles non-binary identifier gracefully" do
    assert :ok = Workspace.remove_issue_workspaces(123)
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "workspace run_before_run_hook returns ok when no hook configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-ws-nohook-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      workspace = Path.join(workspace_root, "test-ws")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.run_before_run_hook(workspace, "TEST-1")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace run_after_run_hook suppresses hook failure" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-ws-afterhook-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      workspace = Path.join(workspace_root, "hook-test")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_run: "exit 1"
      )

      # after_run hook always returns :ok even on failure
      assert capture_log(fn ->
               assert :ok = Workspace.run_after_run_hook(workspace, "TEST-1")
             end) =~ "hook failed"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace run_before_run_hook returns error on hook failure" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-ws-beforehook-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      workspace = Path.join(workspace_root, "hook-fail")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: "exit 42"
      )

      assert capture_log(fn ->
               assert {:error, {:workspace_hook_failed, "before_run", 42, _output}} =
                        Workspace.run_before_run_hook(workspace, "TEST-1")
             end) =~ "hook failed"
    after
      File.rm_rf(workspace_root)
    end
  end
end
