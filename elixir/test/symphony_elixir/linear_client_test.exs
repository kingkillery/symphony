defmodule SymphonyElixir.Linear.ClientTest do
  use SymphonyElixir.TestSupport

  describe "graphql/3" do
    test "returns parsed body on 200 response" do
      request_fun = fn _payload, _headers ->
        {:ok, %{status: 200, body: %{"data" => %{"issues" => []}}}}
      end

      assert {:ok, %{"data" => %{"issues" => []}}} =
               Client.graphql("query { issues { nodes { id } } }", %{}, request_fun: request_fun)
    end

    test "returns error on non-200 status" do
      request_fun = fn _payload, _headers ->
        {:ok, %{status: 429, body: "rate limited"}}
      end

      assert {:error, {:linear_api_status, 429}} =
               Client.graphql("query {}", %{}, request_fun: request_fun)
    end

    test "returns error on request failure" do
      request_fun = fn _payload, _headers ->
        {:error, :timeout}
      end

      assert {:error, {:linear_api_request, :timeout}} =
               Client.graphql("query {}", %{}, request_fun: request_fun)
    end

    test "includes operation_name when provided" do
      parent = self()

      request_fun = fn payload, _headers ->
        send(parent, {:payload, payload})
        {:ok, %{status: 200, body: %{}}}
      end

      Client.graphql("query {}", %{}, request_fun: request_fun, operation_name: "MyQuery")
      assert_received {:payload, %{"operationName" => "MyQuery"}}
    end

    test "omits operation_name when empty string" do
      parent = self()

      request_fun = fn payload, _headers ->
        send(parent, {:payload, payload})
        {:ok, %{status: 200, body: %{}}}
      end

      Client.graphql("query {}", %{}, request_fun: request_fun, operation_name: "  ")
      assert_received {:payload, payload}
      refute Map.has_key?(payload, "operationName")
    end

    test "returns error when api key is nil" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

      previous = System.get_env("LINEAR_API_KEY")
      on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)
      System.delete_env("LINEAR_API_KEY")

      assert {:error, {:linear_api_request, :missing_linear_api_token}} =
               Client.graphql("query {}")
    end
  end

  describe "normalize_issue_for_test/1" do
    test "normalizes a full issue map" do
      issue_map = %{
        "id" => "issue-1",
        "identifier" => "MT-100",
        "title" => "Test issue",
        "description" => "A test",
        "priority" => 2,
        "state" => %{"name" => "In Progress"},
        "branchName" => "mt-100",
        "url" => "https://linear.app/issue/MT-100",
        "assignee" => %{"id" => "user-1"},
        "labels" => %{"nodes" => [%{"name" => "Bug"}, %{"name" => "Critical"}]},
        "inverseRelations" => %{"nodes" => []},
        "createdAt" => "2025-01-15T10:00:00.000Z",
        "updatedAt" => "2025-01-15T12:00:00.000Z"
      }

      issue = Client.normalize_issue_for_test(issue_map)
      assert issue.id == "issue-1"
      assert issue.identifier == "MT-100"
      assert issue.title == "Test issue"
      assert issue.priority == 2
      assert issue.state == "In Progress"
      assert issue.branch_name == "mt-100"
      assert issue.labels == ["bug", "critical"]
      assert issue.blocked_by == []
      assert issue.assigned_to_worker == true
      assert %DateTime{} = issue.created_at
    end

    test "handles nil priority" do
      issue = Client.normalize_issue_for_test(%{"id" => "i1", "priority" => nil})
      assert issue.priority == nil
    end

    test "handles non-integer priority" do
      issue = Client.normalize_issue_for_test(%{"id" => "i1", "priority" => "high"})
      assert issue.priority == nil
    end

    test "handles nil assignee" do
      issue = Client.normalize_issue_for_test(%{"id" => "i1", "assignee" => nil})
      assert issue.assignee_id == nil
      assert issue.assigned_to_worker == true
    end

    test "handles missing labels" do
      issue = Client.normalize_issue_for_test(%{"id" => "i1"})
      assert issue.labels == []
    end

    test "handles invalid datetime" do
      issue = Client.normalize_issue_for_test(%{"id" => "i1", "createdAt" => "not-a-date"})
      assert issue.created_at == nil
    end

    test "handles nil datetime" do
      issue = Client.normalize_issue_for_test(%{"id" => "i1", "createdAt" => nil})
      assert issue.created_at == nil
    end

    test "extracts blockers from inverse relations" do
      issue_map = %{
        "id" => "i1",
        "inverseRelations" => %{
          "nodes" => [
            %{
              "type" => "blocks",
              "issue" => %{
                "id" => "blocker-1",
                "identifier" => "MT-50",
                "state" => %{"name" => "Todo"}
              }
            },
            %{
              "type" => "relates_to",
              "issue" => %{"id" => "related-1", "identifier" => "MT-51", "state" => %{"name" => "Todo"}}
            }
          ]
        }
      }

      issue = Client.normalize_issue_for_test(issue_map)
      assert length(issue.blocked_by) == 1
      assert hd(issue.blocked_by).id == "blocker-1"
    end
  end

  describe "normalize_issue_for_test/2 with assignee filter" do
    test "marks issue as assigned_to_worker when assignee matches" do
      issue_map = %{"id" => "i1", "assignee" => %{"id" => "user-abc"}}
      issue = Client.normalize_issue_for_test(issue_map, "user-abc")
      assert issue.assigned_to_worker == true
    end

    test "marks issue as not assigned_to_worker when assignee differs" do
      issue_map = %{"id" => "i1", "assignee" => %{"id" => "user-abc"}}
      issue = Client.normalize_issue_for_test(issue_map, "user-xyz")
      assert issue.assigned_to_worker == false
    end

    test "marks issue as not assigned_to_worker when no assignee" do
      issue_map = %{"id" => "i1", "assignee" => nil}
      issue = Client.normalize_issue_for_test(issue_map, "user-abc")
      assert issue.assigned_to_worker == false
    end

    test "handles nil assignee filter" do
      issue_map = %{"id" => "i1", "assignee" => %{"id" => "user-abc"}}
      issue = Client.normalize_issue_for_test(issue_map, nil)
      assert issue.assigned_to_worker == true
    end
  end

  describe "next_page_cursor_for_test/1" do
    test "returns ok with cursor when has_next_page is true" do
      assert {:ok, "cursor-abc"} =
               Client.next_page_cursor_for_test(%{has_next_page: true, end_cursor: "cursor-abc"})
    end

    test "returns error when has_next_page but no cursor" do
      assert {:error, :linear_missing_end_cursor} =
               Client.next_page_cursor_for_test(%{has_next_page: true, end_cursor: nil})
    end

    test "returns error when has_next_page but empty cursor" do
      assert {:error, :linear_missing_end_cursor} =
               Client.next_page_cursor_for_test(%{has_next_page: true, end_cursor: ""})
    end

    test "returns done when has_next_page is false" do
      assert :done = Client.next_page_cursor_for_test(%{has_next_page: false, end_cursor: nil})
    end

    test "returns done when has_next_page is nil" do
      assert :done = Client.next_page_cursor_for_test(%{has_next_page: nil})
    end
  end

  describe "merge_issue_pages_for_test/1" do
    test "merges empty list" do
      assert [] = Client.merge_issue_pages_for_test([])
    end

    test "merges single page" do
      issues = [%Issue{id: "i1"}, %Issue{id: "i2"}]
      result = Client.merge_issue_pages_for_test([issues])
      assert length(result) == 2
      assert Enum.map(result, & &1.id) == ["i1", "i2"]
    end

    test "merges multiple pages preserving order" do
      page1 = [%Issue{id: "i1"}, %Issue{id: "i2"}]
      page2 = [%Issue{id: "i3"}, %Issue{id: "i4"}]
      result = Client.merge_issue_pages_for_test([page1, page2])
      assert Enum.map(result, & &1.id) == ["i1", "i2", "i3", "i4"]
    end
  end

  describe "fetch_issue_states_by_ids_for_test/2" do
    test "returns empty list for empty ids" do
      assert {:ok, []} =
               Client.fetch_issue_states_by_ids_for_test([], fn _q, _v -> {:ok, %{}} end)
    end

    test "fetches and sorts by requested ID order" do
      graphql_fun = fn _query, %{ids: ids} ->
        nodes =
          Enum.map(ids, fn id ->
            %{
              "id" => id,
              "identifier" => "MT-#{id}",
              "title" => "Issue #{id}",
              "state" => %{"name" => "Todo"},
              "labels" => %{"nodes" => []},
              "inverseRelations" => %{"nodes" => []}
            }
          end)
          |> Enum.reverse()

        {:ok, %{"data" => %{"issues" => %{"nodes" => nodes}}}}
      end

      assert {:ok, issues} =
               Client.fetch_issue_states_by_ids_for_test(["id-b", "id-a", "id-c"], graphql_fun)

      assert Enum.map(issues, & &1.id) == ["id-b", "id-a", "id-c"]
    end

    test "returns error on graphql failure" do
      graphql_fun = fn _query, _vars -> {:error, :boom} end

      assert {:error, :boom} =
               Client.fetch_issue_states_by_ids_for_test(["id-1"], graphql_fun)
    end

    test "returns error on graphql errors response" do
      graphql_fun = fn _query, _vars ->
        {:ok, %{"errors" => [%{"message" => "Something went wrong"}]}}
      end

      assert {:error, {:linear_graphql_errors, _errors}} =
               Client.fetch_issue_states_by_ids_for_test(["id-1"], graphql_fun)
    end

    test "returns error on unknown payload" do
      graphql_fun = fn _query, _vars ->
        {:ok, %{"unexpected" => true}}
      end

      assert {:error, :linear_unknown_payload} =
               Client.fetch_issue_states_by_ids_for_test(["id-1"], graphql_fun)
    end
  end

  describe "fetch_issue_states_by_ids/1" do
    test "returns empty list for empty input" do
      assert {:ok, []} = Client.fetch_issue_states_by_ids([])
    end
  end

  describe "fetch_candidate_issues/0" do
    test "returns error when api token is missing" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

      previous = System.get_env("LINEAR_API_KEY")
      on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)
      System.delete_env("LINEAR_API_KEY")

      assert {:error, :missing_linear_api_token} = Client.fetch_candidate_issues()
    end

    test "returns error when project slug is missing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: "token",
        tracker_project_slug: nil
      )

      assert {:error, :missing_linear_project_slug} = Client.fetch_candidate_issues()
    end
  end

  describe "fetch_issues_by_states/1" do
    test "returns empty list for empty states" do
      assert {:ok, []} = Client.fetch_issues_by_states([])
    end

    test "returns error when api token is missing" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

      previous = System.get_env("LINEAR_API_KEY")
      on_exit(fn -> restore_env("LINEAR_API_KEY", previous) end)
      System.delete_env("LINEAR_API_KEY")

      assert {:error, :missing_linear_api_token} = Client.fetch_issues_by_states(["Todo"])
    end
  end
end
