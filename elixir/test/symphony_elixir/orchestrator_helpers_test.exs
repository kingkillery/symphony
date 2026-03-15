defmodule SymphonyElixir.OrchestratorHelpersTest do
  use SymphonyElixir.TestSupport

  describe "should_dispatch_issue_for_test/2" do
    test "returns true for active state candidate" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        retry_attempts: %{},
        max_concurrent_agents: 10,
        worker_ssh_hosts: []
      }

      issue = %Issue{
        id: "i1",
        identifier: "MT-1",
        state: "Todo",
        assigned_to_worker: true,
        blocked_by: []
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == true
    end

    test "returns false for already running issue" do
      state = %Orchestrator.State{
        running: %{"i1" => %{pid: self()}},
        claimed: MapSet.new(["i1"]),
        retry_attempts: %{},
        max_concurrent_agents: 10,
        worker_ssh_hosts: []
      }

      issue = %Issue{
        id: "i1",
        identifier: "MT-1",
        state: "Todo",
        assigned_to_worker: true,
        blocked_by: []
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == false
    end

    test "returns false for already claimed issue" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(["i1"]),
        retry_attempts: %{},
        max_concurrent_agents: 10,
        worker_ssh_hosts: []
      }

      issue = %Issue{
        id: "i1",
        identifier: "MT-1",
        state: "Todo",
        assigned_to_worker: true,
        blocked_by: []
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == false
    end

    test "returns false for issue in terminal state" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        retry_attempts: %{},
        max_concurrent_agents: 10,
        worker_ssh_hosts: []
      }

      issue = %Issue{
        id: "i1",
        identifier: "MT-1",
        state: "Closed",
        assigned_to_worker: true,
        blocked_by: []
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == false
    end

    test "returns false for issue not assigned to worker" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        retry_attempts: %{},
        max_concurrent_agents: 10,
        worker_ssh_hosts: []
      }

      issue = %Issue{
        id: "i1",
        identifier: "MT-1",
        state: "Todo",
        assigned_to_worker: false,
        blocked_by: []
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == false
    end

    test "returns false for issue blocked by active non-terminal issue" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        retry_attempts: %{},
        max_concurrent_agents: 10,
        worker_ssh_hosts: []
      }

      issue = %Issue{
        id: "i1",
        identifier: "MT-1",
        state: "Todo",
        assigned_to_worker: true,
        blocked_by: [%{id: "blocker-1", identifier: "MT-0", state: "Todo"}]
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == false
    end

    test "returns true for issue blocked only by terminal issues" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        retry_attempts: %{},
        max_concurrent_agents: 10,
        worker_ssh_hosts: []
      }

      issue = %Issue{
        id: "i1",
        identifier: "MT-1",
        state: "Todo",
        assigned_to_worker: true,
        blocked_by: [%{id: "blocker-1", identifier: "MT-0", state: "Done"}]
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == true
    end

    test "returns false for issue in retry backoff queue" do
      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        retry_attempts: %{"i1" => %{attempt: 1, due_at_ms: System.monotonic_time(:millisecond) + 30_000}},
        max_concurrent_agents: 10,
        worker_ssh_hosts: []
      }

      issue = %Issue{
        id: "i1",
        identifier: "MT-1",
        state: "Todo",
        assigned_to_worker: true,
        blocked_by: []
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == false
    end
  end

  describe "sort_issues_for_dispatch_for_test/1" do
    test "sorts by priority (urgent first)" do
      issues = [
        %Issue{id: "i3", priority: nil},
        %Issue{id: "i1", priority: 1},
        %Issue{id: "i2", priority: 2}
      ]

      sorted = Orchestrator.sort_issues_for_dispatch_for_test(issues)
      assert Enum.map(sorted, & &1.id) == ["i1", "i2", "i3"]
    end

    test "handles empty list" do
      assert [] = Orchestrator.sort_issues_for_dispatch_for_test([])
    end

    test "handles all nil priority" do
      issues = [%Issue{id: "i1", priority: nil}, %Issue{id: "i2", priority: nil}]
      sorted = Orchestrator.sort_issues_for_dispatch_for_test(issues)
      assert length(sorted) == 2
    end
  end

  describe "select_worker_host_for_test/2" do
    test "returns nil when no ssh_hosts configured" do
      state = %Orchestrator.State{
        running: %{},
        worker_ssh_hosts: [],
        max_concurrent_agents: 10,
        worker_max_concurrent_agents_per_host: nil
      }

      assert Orchestrator.select_worker_host_for_test(state, nil) == nil
    end

    test "returns preferred host when available" do
      state = %Orchestrator.State{
        running: %{},
        worker_ssh_hosts: ["host-a", "host-b"],
        max_concurrent_agents: 10,
        worker_max_concurrent_agents_per_host: 5
      }

      assert Orchestrator.select_worker_host_for_test(state, "host-a") == "host-a"
    end

    test "returns no_worker_capacity when all hosts full" do
      state = %Orchestrator.State{
        running: %{
          "i1" => %{worker_host: "host-a"},
          "i2" => %{worker_host: "host-b"}
        },
        worker_ssh_hosts: ["host-a", "host-b"],
        max_concurrent_agents: 10,
        worker_max_concurrent_agents_per_host: 1
      }

      assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
    end
  end

  describe "revalidate_issue_for_dispatch_for_test/2" do
    test "returns ok when issue is still active" do
      fetcher = fn [id] ->
        {:ok, [%Issue{id: id, identifier: "MT-1", state: "Todo"}]}
      end

      issue = %Issue{id: "i1", identifier: "MT-1", state: "Todo"}
      assert {:ok, refreshed} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fetcher)
      assert refreshed.id == "i1"
    end

    test "returns skip when issue moves to terminal state" do
      fetcher = fn [_id] ->
        {:ok, [%Issue{id: "i1", identifier: "MT-1", state: "Done"}]}
      end

      issue = %Issue{id: "i1", identifier: "MT-1", state: "Todo"}
      assert {:skip, _refreshed} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fetcher)
    end

    test "returns skip missing when issue not found" do
      fetcher = fn [_id] ->
        {:ok, []}
      end

      issue = %Issue{id: "i1", identifier: "MT-1", state: "Todo"}
      assert {:skip, :missing} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fetcher)
    end

    test "returns error when fetcher fails" do
      fetcher = fn [_id] ->
        {:error, :network_timeout}
      end

      issue = %Issue{id: "i1", identifier: "MT-1", state: "Todo"}
      assert {:error, :network_timeout} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fetcher)
    end
  end
end
