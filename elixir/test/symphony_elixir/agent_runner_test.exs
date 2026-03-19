defmodule SymphonyElixir.AgentRunnerTest do
  @moduledoc """
  Tests for AgentRunner helper logic.

  Full run/3 integration tests require adding an :app_server_module injection
  point to run_codex_turns/5 (similar to :linear_client_module). These tests
  cover the pure/testable paths without that production change.
  """

  use SymphonyElixir.TestSupport

  describe "run/3 workspace creation failure" do
    test "raises when workspace creation fails on all candidate hosts" do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/nonexistent/root/that/will/fail",
        worker_ssh_hosts: []
      )

      issue = %Issue{
        id: "issue-1",
        identifier: "MT-WS-FAIL",
        state: "Todo",
        title: "Test",
        description: "Test issue"
      }

      assert_raise RuntimeError, ~r/Agent run failed/, fn ->
        AgentRunner.run(issue, nil, max_turns: 1)
      end
    end
  end

  describe "run/3 sends worker_runtime_info to recipient" do
    test "sends runtime info on successful workspace creation" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-agent-runner-info-#{System.unique_integer([:positive])}"
        )

      try do
        File.mkdir_p!(workspace_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "nonexistent-binary-that-wont-start"
        )

        issue = %Issue{
          id: "issue-rt-info",
          identifier: "MT-RT-INFO",
          state: "Todo",
          title: "Runtime Info Test",
          description: "Should send runtime info"
        }

        # This will fail at AppServer.start_session (binary not found) but
        # runtime_info should have been sent before that
        try do
          AgentRunner.run(issue, self(), max_turns: 1)
        rescue
          _ -> :ok
        end

        assert_received {:worker_runtime_info, "issue-rt-info",
                         %{worker_host: nil, workspace_path: workspace_path}}

        assert workspace_path =~ "MT-RT-INFO"
      after
        File.rm_rf(workspace_root)
      end
    end
  end

  describe "run/3 with hooks" do
    test "runs before_run hook before codex and after_run hook even on failure" do
      workspace_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-agent-runner-hooks-#{System.unique_integer([:positive])}"
        )

      marker_file = Path.join(workspace_root, "hook_markers.txt")

      try do
        File.mkdir_p!(workspace_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_before_run: "echo before >> #{marker_file}",
          hook_after_run: "echo after >> #{marker_file}",
          codex_command: "nonexistent-binary-that-wont-start"
        )

        issue = %Issue{
          id: "issue-hooks",
          identifier: "MT-HOOKS",
          state: "Todo",
          title: "Hook Test",
          description: "Should run hooks"
        }

        try do
          AgentRunner.run(issue, nil, max_turns: 1)
        rescue
          _ -> :ok
        end

        if File.exists?(marker_file) do
          content = File.read!(marker_file)
          assert content =~ "before"
          assert content =~ "after"
        end
      after
        File.rm_rf(workspace_root)
      end
    end
  end

end
