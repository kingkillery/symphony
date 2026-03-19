defmodule SymphonyElixir.RuntimeStateStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RuntimeStateStore

  test "persists and loads runtime state" do
    log_root = Path.join(System.tmp_dir!(), "symphony-runtime-store-#{System.unique_integer([:positive])}")
    log_file = Path.join(log_root, "log/symphony.log")
    previous = Application.get_env(:symphony_elixir, :log_file)

    Application.put_env(:symphony_elixir, :log_file, log_file)

    on_exit(fn ->
      if previous, do: Application.put_env(:symphony_elixir, :log_file, previous), else: Application.delete_env(:symphony_elixir, :log_file)
      File.rm_rf(log_root)
    end)

    assert :ok =
             RuntimeStateStore.persist(%{
               "claimed" => ["issue-1"],
               "retry_attempts" => %{"issue-1" => %{"attempt" => 2}}
             })

    assert {:ok, %{"claimed" => ["issue-1"], "retry_attempts" => %{"issue-1" => %{"attempt" => 2}}}} =
             RuntimeStateStore.load()
  end
end
