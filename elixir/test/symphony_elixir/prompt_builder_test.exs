defmodule SymphonyElixir.PromptBuilderTest do
  use SymphonyElixir.TestSupport

  test "renders issue fields into template" do
    write_workflow_file!(workflow_file_path(),
      prompt: "Issue {{ issue.identifier }}: {{ issue.title }}\n{{ issue.description }}"
    )

    issue = %Issue{
      id: "issue-1",
      identifier: "PROJ-123",
      title: "Fix the bug",
      description: "Something is broken"
    }

    result = PromptBuilder.build_prompt(issue)

    assert result =~ "PROJ-123"
    assert result =~ "Fix the bug"
    assert result =~ "Something is broken"
  end

  test "renders issue with nil description using default config prompt" do
    # Use blank prompt to fall back to Config.workflow_prompt() which has identifier/title/description handling
    write_workflow_file!(workflow_file_path(), prompt: "   ")

    issue = %Issue{
      id: "issue-1",
      identifier: "PROJ-456",
      title: "No description issue",
      description: nil
    }

    result = PromptBuilder.build_prompt(issue)

    assert result =~ "PROJ-456"
    assert result =~ "No description provided."
  end

  test "passes attempt number into template context" do
    write_workflow_file!(workflow_file_path(),
      prompt: "Attempt: {{ attempt }}"
    )

    issue = %Issue{id: "issue-1", identifier: "X-1", title: "t"}

    result = PromptBuilder.build_prompt(issue, attempt: 3)
    assert result =~ "3"
  end

  test "converts DateTime fields to ISO8601 strings" do
    write_workflow_file!(workflow_file_path(),
      prompt: "Created: {{ issue.created_at }}"
    )

    issue = %Issue{
      id: "issue-1",
      identifier: "X-1",
      title: "t",
      created_at: ~U[2025-01-15 10:30:00Z]
    }

    result = PromptBuilder.build_prompt(issue)
    assert result =~ "2025-01-15T10:30:00Z"
  end

  test "converts labels list into template-accessible values" do
    write_workflow_file!(workflow_file_path(),
      prompt: "{% for label in issue.labels %}{{ label }} {% endfor %}"
    )

    issue = %Issue{
      id: "issue-1",
      identifier: "X-1",
      title: "t",
      labels: ["bug", "urgent"]
    }

    result = PromptBuilder.build_prompt(issue)
    assert result =~ "bug"
    assert result =~ "urgent"
  end

  test "falls back to default prompt when workflow prompt is blank" do
    write_workflow_file!(workflow_file_path(), prompt: "   ")

    issue = %Issue{
      id: "issue-1",
      identifier: "PROJ-789",
      title: "Default prompt test",
      description: "desc"
    }

    result = PromptBuilder.build_prompt(issue)

    # Default prompt template includes identifier and title
    assert result =~ "PROJ-789"
    assert result =~ "Default prompt test"
  end

  test "raises on malformed liquid template" do
    write_workflow_file!(workflow_file_path(),
      prompt: "{% if unclosed"
    )

    issue = %Issue{id: "issue-1", identifier: "X-1", title: "t"}

    assert_raise RuntimeError, ~r/template_parse_error/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "raises when workflow is unavailable" do
    # Point to a non-existent file
    Workflow.set_workflow_file_path("/tmp/nonexistent-workflow-#{System.unique_integer([:positive])}.md")

    issue = %Issue{id: "issue-1", identifier: "X-1", title: "t"}

    assert_raise RuntimeError, ~r/workflow_unavailable/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  defp workflow_file_path do
    Workflow.workflow_file_path()
  end
end
