defmodule SymphonyElixirWeb.PresenterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.Presenter

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    def init(snapshot), do: {:ok, snapshot}

    def handle_call(:snapshot, _from, snapshot) do
      {:reply, snapshot, snapshot}
    end

    def handle_call(:request_refresh, _from, snapshot) do
      {:reply, %{queued: true, coalesced: false, requested_at: DateTime.utc_now()}, snapshot}
    end
  end

  defp running_entry(overrides \\ %{}) do
    Map.merge(
      %{
        issue_id: "issue-1",
        identifier: "MT-100",
        state: "running",
        session_id: "thread-abc123",
        worker_host: nil,
        workspace_path: "/tmp/workspaces/MT-100",
        codex_app_server_pid: "4242",
        codex_input_tokens: 100,
        codex_output_tokens: 50,
        codex_total_tokens: 150,
        runtime_seconds: 300,
        turn_count: 3,
        last_codex_event: :notification,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        started_at: DateTime.utc_now()
      },
      overrides
    )
  end

  defp retry_entry(overrides \\ %{}) do
    Map.merge(
      %{
        issue_id: "issue-2",
        identifier: "MT-200",
        attempt: 2,
        due_in_ms: 5_000,
        error: "rate limit",
        worker_host: nil,
        workspace_path: "/tmp/workspaces/MT-200"
      },
      overrides
    )
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        running: [],
        retrying: [],
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: nil
      },
      overrides
    )
  end

  describe "state_payload/2" do
    test "returns running and retrying counts with entries" do
      snap = snapshot(%{running: [running_entry()], retrying: [retry_entry()]})
      {:ok, pid} = FakeOrchestrator.start_link(snap)
      on_exit(fn -> GenServer.stop(pid) end)

      payload = Presenter.state_payload(pid, 5_000)
      assert payload.counts.running == 1
      assert payload.counts.retrying == 1
      assert is_binary(payload.generated_at)
      assert length(payload.running) == 1
      assert length(payload.retrying) == 1
    end

    test "returns empty lists when no issues" do
      snap = snapshot()
      {:ok, pid} = FakeOrchestrator.start_link(snap)
      on_exit(fn -> GenServer.stop(pid) end)

      payload = Presenter.state_payload(pid, 5_000)
      assert payload.counts.running == 0
      assert payload.counts.retrying == 0
    end

    test "returns timeout error when orchestrator times out" do
      snap = :timeout
      {:ok, pid} = FakeOrchestrator.start_link(snap)
      on_exit(fn -> GenServer.stop(pid) end)

      payload = Presenter.state_payload(pid, 5_000)
      assert payload.error.code == "snapshot_timeout"
    end

    test "returns unavailable error" do
      snap = :unavailable
      {:ok, pid} = FakeOrchestrator.start_link(snap)
      on_exit(fn -> GenServer.stop(pid) end)

      payload = Presenter.state_payload(pid, 5_000)
      assert payload.error.code == "snapshot_unavailable"
    end
  end

  describe "issue_payload/3" do
    test "returns issue details when found in running" do
      snap = snapshot(%{running: [running_entry()]})
      {:ok, pid} = FakeOrchestrator.start_link(snap)
      on_exit(fn -> GenServer.stop(pid) end)

      assert {:ok, payload} = Presenter.issue_payload("MT-100", pid, 5_000)
      assert payload.issue_identifier == "MT-100"
      assert payload.status == "running"
      assert payload.workspace.path == "/tmp/workspaces/MT-100"
    end

    test "returns issue details when found in retrying" do
      snap = snapshot(%{retrying: [retry_entry()]})
      {:ok, pid} = FakeOrchestrator.start_link(snap)
      on_exit(fn -> GenServer.stop(pid) end)

      assert {:ok, payload} = Presenter.issue_payload("MT-200", pid, 5_000)
      assert payload.issue_identifier == "MT-200"
      assert payload.status == "retrying"
    end

    test "returns error when issue not found" do
      snap = snapshot()
      {:ok, pid} = FakeOrchestrator.start_link(snap)
      on_exit(fn -> GenServer.stop(pid) end)

      assert {:error, :issue_not_found} = Presenter.issue_payload("MT-999", pid, 5_000)
    end

    test "returns error when snapshot is timeout" do
      snap = :timeout
      {:ok, pid} = FakeOrchestrator.start_link(snap)
      on_exit(fn -> GenServer.stop(pid) end)

      assert {:error, :issue_not_found} = Presenter.issue_payload("MT-100", pid, 5_000)
    end
  end

  describe "refresh_payload/1" do
    test "returns ok with ISO8601 requested_at" do
      snap = snapshot()
      {:ok, pid} = FakeOrchestrator.start_link(snap)
      on_exit(fn -> GenServer.stop(pid) end)

      assert {:ok, payload} = Presenter.refresh_payload(pid)
      assert is_binary(payload.requested_at)
      assert payload.requested_at =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end
  end
end
