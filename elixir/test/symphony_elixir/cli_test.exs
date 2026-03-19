defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "returns usage error when extra positional arguments are provided" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "a.md", "b.md"], deps)
    assert message =~ "Usage:"
  end

  test "returns usage error when --logs-root value is empty" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "--logs-root", "  "], deps)
    assert message =~ "Usage:"
  end

  test "accepts --port and passes it to the port override dep" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn port ->
        send(parent, {:port_set, port})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--port", "4000", "WORKFLOW.md"], deps)
    assert_received {:port_set, 4000}
  end

  test "accepts --port 0 for random port assignment" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn port ->
        send(parent, {:port_set, port})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--port", "0"], deps)
    assert_received {:port_set, 0}
  end

  test "uses last value when --logs-root is specified multiple times" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok =
             CLI.evaluate(
               [@ack_flag, "--logs-root", "first", "--logs-root", "second", "WORKFLOW.md"],
               deps
             )

    assert_received {:logs_root, path}
    assert path == Path.expand("second")
  end

  test "uses last value when --port is specified multiple times" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn port ->
        send(parent, {:port_set, port})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--port", "3000", "--port", "5000"], deps)
    assert_received {:port_set, 5000}
  end

  test "issue create returns structured json for agent callers" do
    parent = self()
    expanded_workflow = Path.expand("WORKFLOW.md")

    deps = %{
      file_regular?: fn path -> path == expanded_workflow end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      create_issue: fn attrs ->
        send(parent, {:create_issue, attrs})
        {:ok, %{"id" => "issue-1", "identifier" => "MT-1"}}
      end
    }

    assert {:ok, output} =
             CLI.evaluate(
               ["issue", "create", @ack_flag, "--title", "New issue", "--team-id", "team-1"],
               deps
             )

    assert_received {:workflow_set, ^expanded_workflow}
    assert_received {:create_issue, %{"title" => "New issue", "team_id" => "team-1"} = attrs}
    assert attrs["current_issue_id"] == nil
    assert Jason.decode!(output)["issue"]["identifier"] == "MT-1"
  end

  test "issue create accepts current issue context without explicit team id" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
      create_issue: fn attrs ->
        assert attrs["current_issue_id"] == "issue-1"
        {:ok, %{"id" => "issue-2", "identifier" => "MT-2"}}
      end
    }

    assert {:ok, output} =
             CLI.evaluate(
               ["issue", "create", @ack_flag, "--title", "Follow on", "--current-issue-id", "issue-1"],
               deps
             )

    assert Jason.decode!(output)["issue"]["identifier"] == "MT-2"
  end
end
