defmodule SymphonyElixir.StatusDashboardTest do
  use SymphonyElixir.TestSupport

  describe "humanize_codex_message/1" do
    test "returns placeholder for nil" do
      assert StatusDashboard.humanize_codex_message(nil) == "no codex message yet"
    end

    test "humanizes turn_completed event" do
      message = %{
        event: :notification,
        message: %{
          "method" => "turn/completed",
          "params" => %{"turn" => %{"status" => "completed"}}
        }
      }

      result = StatusDashboard.humanize_codex_message(message)
      assert is_binary(result)
      assert result =~ "completed"
    end

    test "humanizes turn_started event" do
      message = %{
        event: :notification,
        message: %{
          "method" => "turn/started",
          "params" => %{"turn" => %{"id" => "turn-123"}}
        }
      }

      result = StatusDashboard.humanize_codex_message(message)
      assert is_binary(result)
    end

    test "humanizes exec_command_begin event" do
      message = %{
        event: :notification,
        message: %{
          "method" => "codex/event/exec_command_begin",
          "params" => %{"msg" => %{"command" => "mix test"}}
        }
      }

      result = StatusDashboard.humanize_codex_message(message)
      assert is_binary(result)
      assert result =~ "mix test"
    end

    test "humanizes agent_message_delta event" do
      message = %{
        event: :notification,
        message: %{
          "method" => "codex/event/agent_message_delta",
          "params" => %{"msg" => %{"payload" => %{"delta" => "thinking about it"}}}
        }
      }

      result = StatusDashboard.humanize_codex_message(message)
      assert is_binary(result)
    end

    test "humanizes session_started event" do
      message = %{
        event: :session_started,
        message: %{"session_id" => "sess-abc123"}
      }

      result = StatusDashboard.humanize_codex_message(message)
      assert result =~ "session started"
    end

    test "humanizes message without event key" do
      message = %{
        message: %{
          "method" => "turn/completed",
          "params" => %{}
        }
      }

      result = StatusDashboard.humanize_codex_message(message)
      assert is_binary(result)
    end

    test "humanizes bare map message" do
      message = %{
        "method" => "turn/completed",
        "params" => %{}
      }

      result = StatusDashboard.humanize_codex_message(message)
      assert is_binary(result)
    end

    test "humanizes token_usage message" do
      message = %{
        event: :notification,
        message: %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{
            "tokenUsage" => %{
              "total" => %{
                "inputTokens" => 100,
                "outputTokens" => 50,
                "totalTokens" => 150
              }
            }
          }
        }
      }

      result = StatusDashboard.humanize_codex_message(message)
      assert is_binary(result)
    end
  end

  describe "rolling_tps/3" do
    test "returns 0.0 with empty samples" do
      assert StatusDashboard.rolling_tps([], 1_000, 0) == 0.0
    end

    test "returns 0.0 with single sample" do
      assert StatusDashboard.rolling_tps([{1_000, 100}], 1_000, 100) == 0.0
    end

    test "calculates tps across multiple samples" do
      samples = [{0, 0}, {1_000, 100}]
      tps = StatusDashboard.rolling_tps(samples, 2_000, 200)
      assert tps > 0.0
    end
  end

  describe "throttled_tps/5" do
    test "returns cached value within same second" do
      assert {1, 42.0} = StatusDashboard.throttled_tps(1, 42.0, 1_500, [], 100)
    end

    test "recalculates when second changes" do
      {second, tps} = StatusDashboard.throttled_tps(0, 42.0, 1_000, [{0, 0}], 100)
      assert second == 1
      assert is_float(tps)
    end

    test "recalculates when last_second is nil" do
      {second, tps} = StatusDashboard.throttled_tps(nil, nil, 1_000, [], 0)
      assert is_integer(second)
      assert is_float(tps)
    end
  end

  describe "format_tps_for_test/1" do
    test "formats zero" do
      assert StatusDashboard.format_tps_for_test(0.0) == "0.0"
    end

    test "formats positive value" do
      result = StatusDashboard.format_tps_for_test(42.567)
      assert is_binary(result)
    end
  end

  describe "dashboard_url_for_test/3" do
    test "returns nil when configured port is nil" do
      assert StatusDashboard.dashboard_url_for_test("localhost", nil, nil) == nil
    end

    test "returns url with configured port" do
      assert StatusDashboard.dashboard_url_for_test("localhost", 4000, nil) ==
               "http://localhost:4000/"
    end

    test "returns url with bound port overriding configured" do
      assert StatusDashboard.dashboard_url_for_test("localhost", 4000, 4001) ==
               "http://localhost:4001/"
    end

    test "normalizes 0.0.0.0 host to 127.0.0.1" do
      assert StatusDashboard.dashboard_url_for_test("0.0.0.0", 4000, nil) ==
               "http://127.0.0.1:4000/"
    end

    test "normalizes :: host to 127.0.0.1" do
      assert StatusDashboard.dashboard_url_for_test("::", 4000, nil) ==
               "http://127.0.0.1:4000/"
    end

    test "wraps bare IPv6 address in brackets" do
      assert StatusDashboard.dashboard_url_for_test("::1", 4000, nil) ==
               "http://[::1]:4000/"
    end

    test "passes through already-bracketed IPv6" do
      assert StatusDashboard.dashboard_url_for_test("[::1]", 4000, nil) ==
               "http://[::1]:4000/"
    end

    test "returns nil for port 0" do
      assert StatusDashboard.dashboard_url_for_test("localhost", 0, nil) == nil
    end
  end

  describe "GenServer lifecycle" do
    test "start_link with custom name and enabled override" do
      name = Module.concat(__MODULE__, :TestDashboard)

      {:ok, pid} =
        StatusDashboard.start_link(
          name: name,
          enabled: true,
          refresh_ms: 60_000,
          render_interval_ms: 16,
          render_fun: fn _content -> :ok end
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert Process.alive?(pid)
    end

    test "disabled dashboard ignores tick and refresh messages" do
      name = Module.concat(__MODULE__, :DisabledDashboard)

      {:ok, pid} =
        StatusDashboard.start_link(
          name: name,
          enabled: false,
          refresh_ms: 60_000,
          render_interval_ms: 16,
          render_fun: fn _content -> :ok end
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      send(pid, :tick)
      send(pid, :refresh)
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "mismatched flush_render timer ref is ignored" do
      name = Module.concat(__MODULE__, :MismatchFlushDashboard)

      {:ok, pid} =
        StatusDashboard.start_link(
          name: name,
          enabled: true,
          refresh_ms: 60_000,
          render_interval_ms: 16,
          render_fun: fn _content -> :ok end
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      stale_ref = make_ref()
      send(pid, {:flush_render, stale_ref})
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "notify_update/1" do
    test "sends refresh to a running dashboard" do
      name = Module.concat(__MODULE__, :NotifyDashboard)

      {:ok, pid} =
        StatusDashboard.start_link(
          name: name,
          enabled: true,
          refresh_ms: 60_000,
          render_interval_ms: 16,
          render_fun: fn _content -> :ok end
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert :ok = StatusDashboard.notify_update(name)
    end

    test "returns ok when server is not running" do
      assert :ok = StatusDashboard.notify_update(:nonexistent_dashboard)
    end
  end
end
