defmodule SymphonyElixir.WorkflowStoreTest do
  use ExUnit.Case

  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore

  setup do
    dir = Path.join(System.tmp_dir!(), "wfstore-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    workflow_path = Path.join(dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: "memory"
    ---
    Initial prompt.
    """)

    # Stop existing WorkflowStore if running
    if pid = Process.whereis(WorkflowStore) do
      GenServer.stop(pid, :normal)
      Process.sleep(10)
    end

    prev_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    Application.put_env(:symphony_elixir, :workflow_file_path, workflow_path)

    on_exit(fn ->
      if pid = Process.whereis(WorkflowStore) do
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end
      end

      if prev_path,
        do: Application.put_env(:symphony_elixir, :workflow_file_path, prev_path),
        else: Application.delete_env(:symphony_elixir, :workflow_file_path)

      File.rm_rf!(dir)
    end)

    %{dir: dir, workflow_path: workflow_path}
  end

  test "start_link initializes and current returns the workflow", %{workflow_path: _path} do
    assert {:ok, pid} = WorkflowStore.start_link()
    assert is_pid(pid)

    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.prompt == "Initial prompt."
  end

  test "start_link fails when workflow file is missing" do
    Application.put_env(:symphony_elixir, :workflow_file_path, "/tmp/definitely-not-here-#{System.unique_integer([:positive])}.md")

    assert {:error, _reason} = WorkflowStore.start_link()
  end

  test "force_reload picks up file changes", %{workflow_path: path} do
    {:ok, _pid} = WorkflowStore.start_link()

    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.prompt == "Initial prompt."

    # Update the file
    File.write!(path, """
    ---
    tracker:
      kind: "memory"
    ---
    Updated prompt.
    """)

    # Force the file to have a different mtime
    Process.sleep(50)

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, updated} = WorkflowStore.current()
    assert updated.prompt == "Updated prompt."
  end

  test "reload failure preserves last known good workflow", %{workflow_path: path} do
    {:ok, _pid} = WorkflowStore.start_link()

    assert {:ok, initial} = WorkflowStore.current()
    assert initial.prompt == "Initial prompt."

    # Delete the workflow file
    File.rm!(path)

    # force_reload should return error but current should still work
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, preserved} = WorkflowStore.current()
    assert preserved.prompt == "Initial prompt."
  end

  test "current falls back to Workflow.load when GenServer not running" do
    # WorkflowStore is not started in this test
    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.prompt == "Initial prompt."
  end

  test "force_reload falls back to Workflow.load when GenServer not running" do
    assert :ok = WorkflowStore.force_reload()
  end

  test "path change triggers full reload", %{dir: dir} do
    {:ok, _pid} = WorkflowStore.start_link()

    # Create a new workflow file at a different path
    new_path = Path.join(dir, "WORKFLOW2.md")

    File.write!(new_path, """
    ---
    tracker:
      kind: "memory"
    ---
    Different file prompt.
    """)

    # Switch to the new path
    Application.put_env(:symphony_elixir, :workflow_file_path, new_path)

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, workflow} = WorkflowStore.current()
    assert workflow.prompt == "Different file prompt."
  end
end
