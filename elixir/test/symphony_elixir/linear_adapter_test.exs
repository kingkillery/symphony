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
  end
end
