defmodule SymphonyElixir.Linear.AdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Adapter

  setup do
    # Store current config and set our fake client module
    prev = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, __MODULE__.FakeClient)

    on_exit(fn ->
      if prev, do: Application.put_env(:symphony_elixir, :linear_client_module, prev),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    # Start an agent to store fake client responses
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    Process.put(:fake_client_agent, agent)
    :ok
  end

  # -- create_comment/2 --

  test "create_comment succeeds when GraphQL returns success: true" do
    set_graphql_response(fn _query, _vars ->
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    end)

    assert :ok = Adapter.create_comment("issue-1", "Hello")
  end

  test "create_comment returns error when success is false" do
    set_graphql_response(fn _query, _vars ->
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    end)

    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "Hello")
  end

  test "create_comment propagates GraphQL client error" do
    set_graphql_response(fn _query, _vars ->
      {:error, :network_timeout}
    end)

    assert {:error, :network_timeout} = Adapter.create_comment("issue-1", "Hello")
  end

  test "create_comment returns error on unexpected response shape" do
    set_graphql_response(fn _query, _vars ->
      {:ok, %{"data" => %{"commentCreate" => nil}}}
    end)

    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "Hello")
  end

  # -- update_issue_state/2 --

  test "update_issue_state succeeds when state resolves and update returns success" do
    set_graphql_response(fn query, _vars ->
      if query =~ "SymphonyResolveStateId" do
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{
                 "states" => %{
                   "nodes" => [%{"id" => "state-id-123"}]
                 }
               }
             }
           }
         }}
      else
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end)

    assert :ok = Adapter.update_issue_state("issue-1", "In Progress")
  end

  test "update_issue_state returns error when state not found" do
    set_graphql_response(fn _query, _vars ->
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{
               "states" => %{
                 "nodes" => []
               }
             }
           }
         }
       }}
    end)

    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Nonexistent")
  end

  test "update_issue_state propagates state lookup GraphQL error" do
    set_graphql_response(fn _query, _vars ->
      {:error, :api_error}
    end)

    assert {:error, :api_error} = Adapter.update_issue_state("issue-1", "Done")
  end

  test "update_issue_state returns error when update mutation returns success: false" do
    set_graphql_response(fn query, _vars ->
      if query =~ "SymphonyResolveStateId" do
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{
                 "states" => %{
                   "nodes" => [%{"id" => "state-id-456"}]
                 }
               }
             }
           }
         }}
      else
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      end
    end)

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "In Progress")
  end

  # -- delegation functions --

  test "fetch_candidate_issues delegates to client module" do
    set_fetch_response(:fetch_candidate_issues, {:ok, [%{id: "1"}]})
    assert {:ok, [%{id: "1"}]} = Adapter.fetch_candidate_issues()
  end

  test "fetch_issues_by_states delegates to client module" do
    set_fetch_response(:fetch_issues_by_states, {:ok, [%{id: "2"}]})
    assert {:ok, [%{id: "2"}]} = Adapter.fetch_issues_by_states(["Todo"])
  end

  test "fetch_issue_states_by_ids delegates to client module" do
    set_fetch_response(:fetch_issue_states_by_ids, {:ok, [%{id: "3", state: "Done"}]})
    assert {:ok, [%{id: "3", state: "Done"}]} = Adapter.fetch_issue_states_by_ids(["3"])
  end

  test "fetch_issue delegates to client module" do
    set_fetch_response(:fetch_issue, {:ok, %{id: "4", identifier: "MT-4"}})
    assert {:ok, %{id: "4", identifier: "MT-4"}} = Adapter.fetch_issue("4")
  end

  test "update_comment succeeds when GraphQL returns success: true" do
    set_graphql_response(fn _query, _vars ->
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
    end)

    assert :ok = Adapter.update_comment("comment-1", "Hello")
  end

  test "create_issue succeeds when team id is provided directly" do
    set_graphql_response(fn query, vars ->
      cond do
        query =~ "mutation SymphonyCreateIssue" ->
          assert vars[:teamId] == "team-1"
          assert vars[:projectId] == "project-1"
          assert vars[:stateId] == "state-1"
          {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "issue-1", "identifier" => "MT-1"}}}}}

        true ->
          {:error, :unexpected}
      end
    end)

    assert {:ok, %{"identifier" => "MT-1"}} =
             Adapter.create_issue(%{
               "title" => "New issue",
               "team_id" => "team-1",
               "project_id" => "project-1",
               "state_id" => "state-1"
             })
  end

  test "create_issue inherits team and project from current issue when needed" do
    set_fetch_response(:fetch_issue, {:ok, %SymphonyElixir.Linear.Issue{id: "issue-0", team_id: "team-2", project_id: "project-2"}})

    set_graphql_response(fn query, vars ->
      cond do
        query =~ "mutation SymphonyCreateIssue" ->
          assert vars[:teamId] == "team-2"
          assert vars[:projectId] == "project-2"
          {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "issue-2", "identifier" => "MT-2"}}}}}

        true ->
          {:error, :unexpected}
      end
    end)

    assert {:ok, %{"identifier" => "MT-2"}} =
             Adapter.create_issue(%{
               "title" => "Inherited issue",
               "current_issue_id" => "issue-0"
             })
  end

  test "transition_issue uses configured lifecycle role" do
    previous = Application.get_env(:symphony_elixir, :workflow_file_path)
    workflow_path = Path.join(System.tmp_dir!(), "symphony-adapter-test-#{System.unique_integer([:positive])}.md")

    SymphonyElixir.TestSupport.write_workflow_file!(workflow_path)
    SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)

    on_exit(fn ->
      if is_binary(previous), do: SymphonyElixir.Workflow.set_workflow_file_path(previous)
      File.rm_rf(workflow_path)
    end)

    set_graphql_response(fn query, _vars ->
      if query =~ "SymphonyResolveStateId" do
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-id-123"}]}}}}}}
      else
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end)

    assert :ok = Adapter.transition_issue("issue-1", "in_progress")
  end

  test "upsert_workpad_comment updates an existing unresolved workpad" do
    set_fetch_response(:fetch_issue, {:ok, %SymphonyElixir.Linear.Issue{id: "issue-1", comments: [%{id: "comment-1", body: "## Codex Workpad\nold", resolved: false}]}})

    set_graphql_response(fn query, _vars ->
      if query =~ "SymphonyUpdateComment" do
        {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
      else
        {:error, :unexpected}
      end
    end)

    assert {:ok, %{id: "comment-1", created: false}} =
             Adapter.upsert_workpad_comment("issue-1", "## Codex Workpad\nnew")
  end

  # -- Fake client helpers --

  defp set_graphql_response(handler) when is_function(handler, 2) do
    agent = Process.get(:fake_client_agent)
    Agent.update(agent, fn state -> Map.put(state, :graphql_handler, handler) end)
  end

  defp set_fetch_response(function_name, response) do
    agent = Process.get(:fake_client_agent)
    Agent.update(agent, fn state -> Map.put(state, function_name, response) end)
  end

  defmodule FakeClient do
    def graphql(query, vars) do
      agent = Process.get(:fake_client_agent)
      handler = Agent.get(agent, fn state -> Map.get(state, :graphql_handler) end)
      handler.(query, vars)
    end

    def fetch_candidate_issues do
      agent = Process.get(:fake_client_agent)
      Agent.get(agent, fn state -> Map.get(state, :fetch_candidate_issues, {:ok, []}) end)
    end

    def fetch_issues_by_states(_states) do
      agent = Process.get(:fake_client_agent)
      Agent.get(agent, fn state -> Map.get(state, :fetch_issues_by_states, {:ok, []}) end)
    end

    def fetch_issue_states_by_ids(_ids) do
      agent = Process.get(:fake_client_agent)
      Agent.get(agent, fn state -> Map.get(state, :fetch_issue_states_by_ids, {:ok, []}) end)
    end

    def fetch_issue(_issue_id) do
      agent = Process.get(:fake_client_agent)
      Agent.get(agent, fn state -> Map.get(state, :fetch_issue, {:error, :missing}) end)
    end
  end
end
