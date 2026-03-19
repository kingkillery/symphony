defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, Linear.Client, Linear.Issue}

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
        body
      }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
      comment {
        id
        body
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @attachment_link_mutation """
  mutation SymphonyAttachmentLinkCreate($issueId: String!, $title: String!, $url: String!) {
    attachmentLinkCreate(input: {issueId: $issueId, title: $title, url: $url}) {
      success
    }
  }
  """

  @team_state_lookup_query """
  query SymphonyResolveTeamStateId($teamId: String!, $stateName: String!) {
    team(id: $teamId) {
      states(filter: {name: {eq: $stateName}}, first: 1) {
        nodes {
          id
        }
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyCreateIssue($title: String!, $teamId: String!, $projectId: String, $description: String, $stateId: String) {
    issueCreate(input: {title: $title, teamId: $teamId, projectId: $projectId, description: $description, stateId: $stateId}) {
      success
      issue {
        id
        identifier
        title
        url
      }
    }
  }
  """

  @issue_relation_mutation """
  mutation SymphonyCreateIssueRelation($issueId: String!, $relatedIssueId: String!, $type: IssueRelationType!) {
    issueRelationCreate(input: {issueId: $issueId, relatedIssueId: $relatedIssueId, type: $type}) {
      success
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec fetch_issue(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def fetch_issue(issue_id) when is_binary(issue_id), do: client_module().fetch_issue(issue_id)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@update_comment_mutation, %{commentId: comment_id, body: body}),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec transition_issue(String.t(), atom() | String.t()) :: :ok | {:error, term()}
  def transition_issue(issue_id, state_role) when is_binary(issue_id) do
    with state_name when is_binary(state_name) <- resolve_transition_state_name(state_role),
         :ok <- update_issue_state(issue_id, state_name) do
      :ok
    else
      nil -> {:error, {:unknown_lifecycle_role, state_role}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec upsert_workpad_comment(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_workpad_comment(issue_id, body, opts \\ [])
      when is_binary(issue_id) and is_binary(body) and is_list(opts) do
    marker = Keyword.get(opts, :marker, Config.workpad_marker())

    with {:ok, %Issue{} = issue} <- fetch_issue(issue_id) do
      case find_workpad_comment(issue.comments, marker) do
        %{id: comment_id} = comment when is_binary(comment_id) ->
          with :ok <- update_comment(comment_id, body) do
            {:ok, %{id: comment_id, body: body, created: false, previous_body: Map.get(comment, :body)}}
          end

        nil ->
          with :ok <- create_comment(issue_id, body),
               {:ok, %Issue{} = refreshed_issue} <- fetch_issue(issue_id),
               %{id: comment_id} <- find_workpad_comment(refreshed_issue.comments, marker) do
            {:ok, %{id: comment_id, body: body, created: true}}
          else
            nil -> {:error, :workpad_comment_not_found_after_create}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @spec attach_external_link(String.t(), map()) :: :ok | {:error, term()}
  def attach_external_link(issue_id, %{} = link) when is_binary(issue_id) do
    with title when is_binary(title) and title != "" <- normalize_link_value(link[:title] || link["title"]),
         url when is_binary(url) and url != "" <- normalize_link_value(link[:url] || link["url"]),
         {:ok, response} <- client_module().graphql(@attachment_link_mutation, %{issueId: issue_id, title: title, url: url}),
         true <- get_in(response, ["data", "attachmentLinkCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :attachment_link_create_failed}
      nil -> {:error, :invalid_external_link}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :attachment_link_create_failed}
    end
  end

  @spec create_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_issue(attrs) when is_map(attrs) do
    with {:ok, issue_input} <- build_issue_input(attrs),
         {:ok, response} <- client_module().graphql(@create_issue_mutation, issue_input),
         true <- get_in(response, ["data", "issueCreate", "success"]) == true,
         %{} = issue <- get_in(response, ["data", "issueCreate", "issue"]) do
      {:ok, issue}
    else
      false -> {:error, :issue_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_create_failed}
    end
  end

  @spec create_related_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_related_issue(attrs) when is_map(attrs) do
    with {:ok, issue} <- create_issue(attrs),
         :ok <- maybe_create_issue_relation(Map.get(issue, "id"), attrs) do
      {:ok, issue}
    else
      false -> {:error, :related_issue_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :related_issue_create_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp resolve_team_state_id(team_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@team_state_lookup_query, %{teamId: team_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp resolve_transition_state_name(role) when is_atom(role), do: Config.lifecycle_state(role)
  defp resolve_transition_state_name(role) when is_binary(role), do: Config.lifecycle_state(normalize_role(role))
  defp resolve_transition_state_name(_role), do: nil

  defp normalize_role(role) when is_binary(role) do
    role
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  defp find_workpad_comment(comments, marker) when is_list(comments) and is_binary(marker) do
    Enum.find(comments, fn
      %{body: body, resolved: resolved} when is_binary(body) and is_boolean(resolved) ->
        String.contains?(body, marker) and resolved == false

      %{body: body} when is_binary(body) ->
        String.contains?(body, marker)

      _ ->
        false
    end)
  end

  defp build_issue_input(attrs) do
    title = normalize_link_value(attrs[:title] || attrs["title"])
    requested_team_id = normalize_link_value(attrs[:team_id] || attrs["team_id"])
    requested_project_id = normalize_link_value(attrs[:project_id] || attrs["project_id"])
    description = normalize_optional_string(attrs[:description] || attrs["description"])

    cond do
      title in [nil, ""] -> {:error, :missing_issue_title}
      true ->
        with {:ok, team_id, project_id} <- resolve_issue_create_context(attrs, requested_team_id, requested_project_id),
             {:ok, state_id} <- maybe_resolve_issue_state_id(attrs, team_id) do
          {:ok,
           %{
             title: title,
              teamId: team_id,
             projectId: project_id,
             description: description,
             stateId: state_id
           }}
        end
    end
  end

  defp resolve_issue_create_context(_attrs, team_id, project_id)
       when is_binary(team_id) and team_id != "" do
    {:ok, team_id, project_id}
  end

  defp resolve_issue_create_context(attrs, _team_id, project_id) do
    case normalize_optional_string(attrs[:current_issue_id] || attrs["current_issue_id"]) do
      nil ->
        {:error, :missing_issue_team_id}

      current_issue_id ->
        with {:ok, %Issue{} = issue} <- fetch_issue(current_issue_id),
             team_id when is_binary(team_id) and team_id != "" <- Map.get(issue, :team_id) do
          {:ok, team_id, project_id || Map.get(issue, :project_id)}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :missing_issue_team_id}
        end
    end
  end

  defp maybe_resolve_issue_state_id(attrs, team_id) do
    case {attrs[:state_id] || attrs["state_id"], attrs[:current_issue_id] || attrs["current_issue_id"], attrs[:state_name] || attrs["state_name"]} do
      {state_id, _, _} when is_binary(state_id) and state_id != "" ->
        {:ok, state_id}

      {_, issue_id, state_name} when is_binary(issue_id) and is_binary(state_name) and state_name != "" ->
        resolve_state_id(issue_id, state_name)

      {_, _, state_name} when is_binary(team_id) and is_binary(state_name) and state_name != "" ->
        resolve_team_state_id(team_id, state_name)

      _ ->
        {:ok, nil}
    end
  end

  defp maybe_create_issue_relation(nil, _attrs), do: {:error, :missing_related_issue_id}

  defp maybe_create_issue_relation(related_issue_id, attrs) when is_binary(related_issue_id) do
    case normalize_optional_string(attrs[:current_issue_id] || attrs["current_issue_id"]) do
      nil ->
        :ok

      issue_id ->
        relation_type =
          normalize_optional_string(attrs[:relation_type] || attrs["relation_type"] || "related")
          |> String.upcase()

        with {:ok, response} <-
               client_module().graphql(@issue_relation_mutation, %{
                 issueId: issue_id,
                 relatedIssueId: related_issue_id,
                 type: relation_type
               }),
             true <- get_in(response, ["data", "issueRelationCreate", "success"]) == true do
          :ok
        else
          false -> {:error, :issue_relation_create_failed}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :issue_relation_create_failed}
        end
    end
  end

  defp normalize_link_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_link_value(_value), do: nil

  defp normalize_optional_string(value), do: normalize_link_value(value)
end
