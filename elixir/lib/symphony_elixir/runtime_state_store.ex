defmodule SymphonyElixir.RuntimeStateStore do
  @moduledoc """
  Persists a small recoverable snapshot of orchestrator state for restart recovery.
  """

  alias SymphonyElixir.LogFile

  @runtime_state_file "runtime_state.json"

  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    path = runtime_state_path()

    case File.read(path) do
      {:ok, content} ->
        Jason.decode(content)

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec persist(map()) :: :ok | {:error, term()}
  def persist(snapshot) when is_map(snapshot) do
    path = runtime_state_path()
    :ok = File.mkdir_p(Path.dirname(path))

    with {:ok, encoded} <- Jason.encode(snapshot, pretty: true) do
      File.write(path, encoded)
    end
  end

  @spec clear() :: :ok | {:error, term()}
  def clear do
    path = runtime_state_path()

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec runtime_state_path() :: Path.t()
  def runtime_state_path do
    log_file = Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
    Path.join(Path.dirname(Path.expand(log_file)), @runtime_state_file)
  end
end
