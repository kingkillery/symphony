defmodule SymphonyElixir.Config.SchemaTest do
  @moduledoc """
  Edge case tests for Config.Schema: parse errors, normalize_keys,
  runtime sandbox policy, and validation boundaries.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}

  # -- parse/1 validation errors --

  test "parse returns error for non-integer polling interval" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "polling" => %{"interval_ms" => "not_a_number"}
             })

    assert message =~ "polling"
  end

  test "parse returns error for negative polling interval" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "polling" => %{"interval_ms" => -1}
             })

    assert message =~ "polling"
  end

  test "parse returns error for zero max_concurrent_agents" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "agent" => %{"max_concurrent_agents" => 0}
             })

    assert message =~ "agent"
  end

  test "parse returns error for non-integer max_turns" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "agent" => %{"max_turns" => "five"}
             })

    assert message =~ "agent"
  end

  test "parse returns error for missing codex command" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "codex" => %{"command" => nil}
             })

    assert message =~ "codex"
  end

  test "parse returns error for zero codex turn_timeout_ms" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "codex" => %{"turn_timeout_ms" => 0}
             })

    assert message =~ "codex"
  end

  test "parse returns error for negative server port" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "server" => %{"port" => -1}
             })

    assert message =~ "server"
  end

  test "parse returns error for zero hooks timeout_ms" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "hooks" => %{"timeout_ms" => 0}
             })

    assert message =~ "hooks"
  end

  # -- normalize_keys edge cases --

  test "parse normalizes atom keys to string keys" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.tracker.kind == "memory"
  end

  test "parse normalizes deeply nested atom keys" do
    assert {:ok, settings} =
             Schema.parse(%{
               codex: %{
                 approval_policy: %{reject: %{sandbox_approval: true, rules: true}}
               }
             })

    assert settings.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true, "rules" => true}
           }
  end

  test "parse handles empty config with all defaults" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.tracker.kind == nil
    assert settings.polling.interval_ms == 30_000
    assert settings.agent.max_concurrent_agents == 10
    assert settings.codex.command == "codex app-server"
  end

  test "parse drops nil values before applying changeset" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "linear", "assignee" => nil},
               "polling" => nil
             })

    assert settings.tracker.kind == "linear"
    assert settings.polling.interval_ms == 30_000
  end

  # -- max_concurrent_agents_by_state validation --

  test "parse rejects blank state name in by_state limits" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "agent" => %{"max_concurrent_agents_by_state" => %{"" => 5}}
             })

    assert message =~ "state names must not be blank"
  end

  test "parse rejects zero limit in by_state limits" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "agent" => %{"max_concurrent_agents_by_state" => %{"todo" => 0}}
             })

    assert message =~ "limits must be positive integers"
  end

  test "parse rejects non-integer limit in by_state limits" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "agent" => %{"max_concurrent_agents_by_state" => %{"todo" => "five"}}
             })

    assert message =~ "limits must be positive integers"
  end

  test "parse normalizes state names to lowercase in by_state limits" do
    assert {:ok, settings} =
             Schema.parse(%{
               "agent" => %{"max_concurrent_agents_by_state" => %{"In Progress" => 3}}
             })

    assert settings.agent.max_concurrent_agents_by_state == %{"in progress" => 3}
  end

  # -- normalize_issue_state --

  test "normalize_issue_state downcases state names" do
    assert Schema.normalize_issue_state("In Progress") == "in progress"
    assert Schema.normalize_issue_state("TODO") == "todo"
    assert Schema.normalize_issue_state("done") == "done"
  end

  # -- resolve_runtime_turn_sandbox_policy --

  test "runtime sandbox policy returns explicit policy when set" do
    explicit = %{"type" => "workspaceWrite", "writableRoots" => ["/custom"]}

    settings = %Schema{
      codex: %Codex{turn_sandbox_policy: explicit},
      workspace: %Schema.Workspace{root: "/tmp/ignored"}
    }

    assert {:ok, ^explicit} = Schema.resolve_runtime_turn_sandbox_policy(settings)
  end

  test "runtime sandbox policy generates default with canonicalized workspace" do
    settings = %Schema{
      codex: %Codex{turn_sandbox_policy: nil},
      workspace: %Schema.Workspace{root: System.tmp_dir!()}
    }

    assert {:ok, policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
    assert policy["type"] == "workspaceWrite"
    assert is_list(policy["writableRoots"])
    assert length(policy["writableRoots"]) == 1
  end

  test "runtime sandbox policy skips canonicalization in remote mode" do
    settings = %Schema{
      codex: %Codex{turn_sandbox_policy: nil},
      workspace: %Schema.Workspace{root: "~/remote-workspace"}
    }

    assert {:ok, policy} = Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)
    assert policy["writableRoots"] == ["~/remote-workspace"]
  end

  test "runtime sandbox policy returns error for non-binary workspace root" do
    settings = %Schema{
      codex: %Codex{turn_sandbox_policy: nil},
      workspace: %Schema.Workspace{root: nil}
    }

    assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, nil}}} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil)
  end

  # -- StringOrMap custom type --

  test "StringOrMap handles dump for string and map" do
    assert {:ok, "hello"} = StringOrMap.dump("hello")
    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(42)
  end

  test "StringOrMap handles load for string and map" do
    assert {:ok, "hello"} = StringOrMap.load("hello")
    assert {:ok, %{"a" => 1}} = StringOrMap.load(%{"a" => 1})
    assert :error = StringOrMap.load(42)
  end

  # -- worker validation --

  test "parse rejects zero max_concurrent_agents_per_host" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "worker" => %{"max_concurrent_agents_per_host" => 0}
             })

    assert message =~ "worker"
  end

  test "parse accepts valid worker ssh_hosts" do
    assert {:ok, settings} =
             Schema.parse(%{
               "worker" => %{"ssh_hosts" => ["host1", "host2"]}
             })

    assert settings.worker.ssh_hosts == ["host1", "host2"]
  end

  # -- observability validation --

  test "parse rejects zero observability refresh_ms" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "observability" => %{"refresh_ms" => 0}
             })

    assert message =~ "observability"
  end
end
