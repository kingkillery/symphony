defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec fetch_issue(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue(issue_id) when is_binary(issue_id) do
    case Enum.find(issue_entries(), &(&1.id == issue_id)) do
      %Issue{} = issue -> {:ok, issue}
      nil -> {:error, :issue_not_found}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) do
    send_event({:memory_tracker_comment_update, comment_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @spec transition_issue(String.t(), atom() | String.t()) :: :ok | {:error, term()}
  def transition_issue(issue_id, state_role) do
    send_event({:memory_tracker_transition_issue, issue_id, state_role})
    :ok
  end

  @spec upsert_workpad_comment(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_workpad_comment(issue_id, body, opts \\ []) do
    marker = Keyword.get(opts, :marker, "## Codex Workpad")
    comment = %{id: "memory-workpad-#{issue_id}", body: body, marker: marker, issue_id: issue_id}
    send_event({:memory_tracker_workpad_upsert, issue_id, body, opts})
    {:ok, comment}
  end

  @spec attach_external_link(String.t(), map()) :: :ok | {:error, term()}
  def attach_external_link(issue_id, link) when is_map(link) do
    send_event({:memory_tracker_link_attachment, issue_id, link})
    :ok
  end

  @spec create_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_issue(attrs) when is_map(attrs) do
    issue = Map.put_new(attrs, :id, "memory-issue")
    send_event({:memory_tracker_issue_create, issue})
    {:ok, issue}
  end

  @spec create_related_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_related_issue(attrs) when is_map(attrs) do
    issue = Map.put_new(attrs, :id, "memory-related-issue")
    send_event({:memory_tracker_related_issue_create, issue})
    {:ok, issue}
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
