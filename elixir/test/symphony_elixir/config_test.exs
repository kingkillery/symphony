defmodule SymphonyElixir.ConfigTest do
  use SymphonyElixir.TestSupport

  describe "max_concurrent_agents_for_state/1" do
    test "returns per-state limit when configured for a matching state" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 10,
        max_concurrent_agents_by_state: %{"todo" => 2, "in_progress" => 5}
      )

      assert Config.max_concurrent_agents_for_state("Todo") == 2
      assert Config.max_concurrent_agents_for_state("In Progress") == 5
    end

    test "returns global limit for unconfigured state names" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 7,
        max_concurrent_agents_by_state: %{"todo" => 2}
      )

      assert Config.max_concurrent_agents_for_state("In Review") == 7
    end

    test "returns global limit for non-binary state names" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 4)
      assert Config.max_concurrent_agents_for_state(nil) == 4
      assert Config.max_concurrent_agents_for_state(123) == 4
    end
  end

  describe "codex_turn_sandbox_policy/1" do
    test "returns resolved policy with nil workspace" do
      write_workflow_file!(Workflow.workflow_file_path())
      policy = Config.codex_turn_sandbox_policy(nil)
      assert is_map(policy)
    end

    test "returns resolved policy with a workspace path" do
      workspace = Path.join(System.tmp_dir!(), "test-workspace-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)

      on_exit(fn -> File.rm_rf(workspace) end)

      write_workflow_file!(Workflow.workflow_file_path())
      policy = Config.codex_turn_sandbox_policy(workspace)
      assert is_map(policy)
    end
  end

  describe "workflow_prompt/0" do
    test "returns prompt from workflow file" do
      write_workflow_file!(Workflow.workflow_file_path(), prompt: "Custom prompt here")
      assert Config.workflow_prompt() == "Custom prompt here\n"
    end

    test "returns default prompt when workflow prompt is empty" do
      write_workflow_file!(Workflow.workflow_file_path(), prompt: "   ")
      prompt = Config.workflow_prompt()
      assert prompt =~ "You are working on a Linear issue"
    end

    test "returns default prompt when workflow errors" do
      Workflow.set_workflow_file_path("/nonexistent/WORKFLOW.md")
      prompt = Config.workflow_prompt()
      assert prompt =~ "You are working on a Linear issue"
    end
  end

  describe "server_port/0" do
    test "returns override port when set in application env" do
      Application.put_env(:symphony_elixir, :server_port_override, 9999)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :server_port_override) end)

      assert Config.server_port() == 9999
    end

    test "returns config port when no override is set" do
      Application.delete_env(:symphony_elixir, :server_port_override)
      write_workflow_file!(Workflow.workflow_file_path(), server_port: 8080)
      assert Config.server_port() == 8080
    end

    test "returns nil when neither override nor config port is set" do
      Application.delete_env(:symphony_elixir, :server_port_override)
      write_workflow_file!(Workflow.workflow_file_path(), server_port: nil)
      assert Config.server_port() == nil
    end
  end

  describe "validate!/0" do
    test "returns error for nil tracker kind" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: nil)
      assert {:error, :missing_tracker_kind} = Config.validate!()
    end

    test "returns error for unsupported tracker kind" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")
      assert {:error, {:unsupported_tracker_kind, "jira"}} = Config.validate!()
    end

    test "returns error for linear tracker without api token" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: nil,
        tracker_project_slug: "slug"
      )

      previous = System.get_env("LINEAR_API_KEY")
      on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)
      System.delete_env("LINEAR_API_KEY")

      assert {:error, :missing_linear_api_token} = Config.validate!()
    end

    test "returns error for linear tracker without project slug" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: "token",
        tracker_project_slug: nil
      )

      assert {:error, :missing_linear_project_slug} = Config.validate!()
    end

  test "returns ok for memory tracker kind" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      assert :ok = Config.validate!()
    end

    test "returns ok for valid linear config" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: "token",
        tracker_project_slug: "slug"
      )

      assert :ok = Config.validate!()
    end
  end

  test "returns configured workpad marker and lifecycle state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_workpad_marker: "## Workpad",
      tracker_lifecycle_states: %{in_progress: "Doing"}
    )

    assert Config.workpad_marker() == "## Workpad"
    assert Config.lifecycle_state(:in_progress) == "Doing"
  end

  describe "codex_runtime_settings/2" do
    test "returns settings with nil workspace" do
      write_workflow_file!(Workflow.workflow_file_path())
      assert {:ok, settings} = Config.codex_runtime_settings(nil)
      assert is_map(settings.approval_policy)
      assert is_binary(settings.thread_sandbox)
      assert is_map(settings.turn_sandbox_policy)
    end

    test "returns settings with a workspace path" do
      workspace = Path.join(System.tmp_dir!(), "test-ws-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      write_workflow_file!(Workflow.workflow_file_path())
      assert {:ok, settings} = Config.codex_runtime_settings(workspace)
      assert is_map(settings.turn_sandbox_policy)
    end

    test "returns error when workflow is invalid" do
      Workflow.set_workflow_file_path("/nonexistent/WORKFLOW.md")
      assert {:error, _reason} = Config.codex_runtime_settings(nil)
    end
  end

  describe "settings!/0" do
    test "raises on missing workflow file with formatted message" do
      Workflow.set_workflow_file_path("/nonexistent/WORKFLOW.md")

      assert_raise ArgumentError, ~r/Missing WORKFLOW.md/, fn ->
        Config.settings!()
      end
    end
  end
end
