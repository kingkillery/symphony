defmodule SymphonyElixir.WorkflowTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow

  setup do
    dir = Path.join(System.tmp_dir!(), "workflow-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "loads a valid workflow with front matter and prompt", %{dir: dir} do
    path = Path.join(dir, "WORKFLOW.md")

    File.write!(path, """
    ---
    tracker:
      kind: "memory"
    ---
    You are an agent.
    """)

    assert {:ok, workflow} = Workflow.load(path)
    assert workflow.config == %{"tracker" => %{"kind" => "memory"}}
    assert workflow.prompt == "You are an agent."
    assert workflow.prompt_template == "You are an agent."
  end

  test "loads a file with no front matter delimiters", %{dir: dir} do
    path = Path.join(dir, "WORKFLOW.md")
    File.write!(path, "Just a plain prompt.")

    assert {:ok, workflow} = Workflow.load(path)
    assert workflow.config == %{}
    assert workflow.prompt == "Just a plain prompt."
  end

  test "loads a file with empty front matter", %{dir: dir} do
    path = Path.join(dir, "WORKFLOW.md")

    File.write!(path, """
    ---
    ---
    Prompt after empty front matter.
    """)

    assert {:ok, workflow} = Workflow.load(path)
    assert workflow.config == %{}
    assert workflow.prompt == "Prompt after empty front matter."
  end

  test "returns error for invalid YAML in front matter", %{dir: dir} do
    path = Path.join(dir, "WORKFLOW.md")

    File.write!(path, """
    ---
    : invalid yaml [[[
    ---
    Prompt text.
    """)

    assert {:error, {:workflow_parse_error, _reason}} = Workflow.load(path)
  end

  test "returns error when front matter is not a map", %{dir: dir} do
    path = Path.join(dir, "WORKFLOW.md")

    File.write!(path, """
    ---
    - item1
    - item2
    ---
    Prompt text.
    """)

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(path)
  end

  test "returns error for missing file" do
    path = "/tmp/nonexistent-workflow-#{System.unique_integer([:positive])}.md"

    assert {:error, {:missing_workflow_file, ^path, :enoent}} = Workflow.load(path)
  end

  test "loads file with front matter that has unclosed delimiter", %{dir: dir} do
    path = Path.join(dir, "WORKFLOW.md")

    File.write!(path, """
    ---
    tracker:
      kind: "memory"
    """)

    # Opening --- but no closing --- means all lines after are treated as front matter
    # with empty prompt lines
    assert {:ok, workflow} = Workflow.load(path)
    assert workflow.config == %{"tracker" => %{"kind" => "memory"}}
    assert workflow.prompt == ""
  end

  test "handles multi-line prompt correctly", %{dir: dir} do
    path = Path.join(dir, "WORKFLOW.md")

    File.write!(path, """
    ---
    tracker:
      kind: "linear"
    ---
    Line 1
    Line 2
    Line 3
    """)

    assert {:ok, workflow} = Workflow.load(path)
    assert workflow.prompt =~ "Line 1"
    assert workflow.prompt =~ "Line 2"
    assert workflow.prompt =~ "Line 3"
  end
end
