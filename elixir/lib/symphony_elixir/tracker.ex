defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue(String.t()) :: {:ok, term()} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback transition_issue(String.t(), atom() | String.t()) :: :ok | {:error, term()}
  @callback upsert_workpad_comment(String.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback attach_external_link(String.t(), map()) :: :ok | {:error, term()}
  @callback create_issue(map()) :: {:ok, map()} | {:error, term()}
  @callback create_related_issue(map()) :: {:ok, map()} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec fetch_issue(String.t()) :: {:ok, term()} | {:error, term()}
  def fetch_issue(issue_id) do
    adapter().fetch_issue(issue_id)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) do
    adapter().update_comment(comment_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec transition_issue(String.t(), atom() | String.t()) :: :ok | {:error, term()}
  def transition_issue(issue_id, state_role) do
    adapter().transition_issue(issue_id, state_role)
  end

  @spec upsert_workpad_comment(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_workpad_comment(issue_id, body, opts \\ []) do
    adapter().upsert_workpad_comment(issue_id, body, opts)
  end

  @spec attach_external_link(String.t(), map()) :: :ok | {:error, term()}
  def attach_external_link(issue_id, link) do
    adapter().attach_external_link(issue_id, link)
  end

  @spec create_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_issue(attrs) do
    adapter().create_issue(attrs)
  end

  @spec create_related_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_related_issue(attrs) do
    adapter().create_related_issue(attrs)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
