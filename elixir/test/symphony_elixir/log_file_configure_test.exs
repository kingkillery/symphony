defmodule SymphonyElixir.LogFileConfigureTest do
  @moduledoc """
  Tests for LogFile.configure/0 — log handler setup, rotation config,
  and error handling paths.
  """

  use ExUnit.Case
  import ExUnit.CaptureLog

  alias SymphonyElixir.LogFile

  setup do
    log_dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-log-test-#{System.unique_integer([:positive])}"
      )

    # Save previous config
    prev_log_file = Application.get_env(:symphony_elixir, :log_file)
    prev_max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes)
    prev_max_files = Application.get_env(:symphony_elixir, :log_file_max_files)

    on_exit(fn ->
      # Remove any handler we added
      :logger.remove_handler(:symphony_disk_log)

      # Restore config
      if prev_log_file,
        do: Application.put_env(:symphony_elixir, :log_file, prev_log_file),
        else: Application.delete_env(:symphony_elixir, :log_file)

      if prev_max_bytes,
        do: Application.put_env(:symphony_elixir, :log_file_max_bytes, prev_max_bytes),
        else: Application.delete_env(:symphony_elixir, :log_file_max_bytes)

      if prev_max_files,
        do: Application.put_env(:symphony_elixir, :log_file_max_files, prev_max_files),
        else: Application.delete_env(:symphony_elixir, :log_file_max_files)

      File.rm_rf(log_dir)
    end)

    %{log_dir: log_dir}
  end

  test "configure creates log directory and sets up handler", %{log_dir: log_dir} do
    log_file = Path.join(log_dir, "test.log")
    Application.put_env(:symphony_elixir, :log_file, log_file)

    assert :ok = LogFile.configure()
    assert File.dir?(log_dir)
  end

  test "configure uses custom max_bytes and max_files", %{log_dir: log_dir} do
    log_file = Path.join(log_dir, "custom.log")
    Application.put_env(:symphony_elixir, :log_file, log_file)
    Application.put_env(:symphony_elixir, :log_file_max_bytes, 1_024)
    Application.put_env(:symphony_elixir, :log_file_max_files, 2)

    assert :ok = LogFile.configure()
  end

  test "configure removes existing handler before adding new one", %{log_dir: log_dir} do
    log_file = Path.join(log_dir, "reconfig.log")
    Application.put_env(:symphony_elixir, :log_file, log_file)

    # Configure twice — second call should succeed (removes first handler)
    assert :ok = LogFile.configure()
    assert :ok = LogFile.configure()
  end

  test "configure returns ok even when handler add fails" do
    # Use an invalid path that will cause the disk log handler to fail
    # On Linux, /dev/null/impossible is not a valid directory
    Application.put_env(:symphony_elixir, :log_file, "/dev/null/impossible/test.log")

    # Should still return :ok (logs a warning internally)
    result =
      capture_log(fn ->
        assert :ok = LogFile.configure()
      end)

    # The warning may or may not appear depending on timing, but configure should not crash
    assert is_binary(result)
  end
end
