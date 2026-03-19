defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Linear.Client, Tracker}

  @linear_graphql_tool "linear_graphql"
  @linear_workflow_tool "linear_workflow"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_workflow_description """
  Execute typed Symphony workflow actions against Linear for issue management, workpad updates, state transitions, and related issue creation.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @linear_workflow_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["action"],
    "properties" => %{
      "action" => %{
        "type" => "string",
        "enum" => ["get_issue_context", "upsert_workpad", "transition_issue", "attach_external_link", "create_issue", "create_followup_issue"]
      },
      "issueId" => %{"type" => "string"},
      "currentIssueId" => %{"type" => "string"},
      "body" => %{"type" => "string"},
      "marker" => %{"type" => "string"},
      "stateRole" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "url" => %{"type" => "string"},
      "description" => %{"type" => ["string", "null"]},
      "teamId" => %{"type" => ["string", "null"]},
      "projectId" => %{"type" => ["string", "null"]},
      "stateId" => %{"type" => ["string", "null"]},
      "stateName" => %{"type" => ["string", "null"]},
      "relationType" => %{"type" => ["string", "null"]}
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_workflow_tool ->
        execute_linear_workflow(arguments, opts)

      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_workflow_tool,
        "description" => @linear_workflow_description,
        "inputSchema" => @linear_workflow_input_schema
      },
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_workflow(arguments, opts) when is_map(arguments) do
    tracker = Keyword.get(opts, :tracker, Tracker)

    with {:ok, action} <- required_string(arguments, "action"),
         {:ok, response} <- run_linear_workflow_action(action, arguments, tracker) do
      dynamic_tool_response(true, encode_payload(%{"ok" => true, "action" => action, "result" => response}))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_workflow(_arguments, _opts) do
    failure_response(tool_error_payload(:invalid_linear_workflow_arguments))
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp run_linear_workflow_action("get_issue_context", arguments, tracker) do
    with {:ok, issue_id} <- required_string(arguments, "issueId"),
         {:ok, issue} <- tracker_call(tracker, :fetch_issue, [issue_id]) do
      {:ok, issue_payload(issue)}
    end
  end

  defp run_linear_workflow_action("upsert_workpad", arguments, tracker) do
    with {:ok, issue_id} <- required_string(arguments, "issueId"),
         {:ok, body} <- required_string(arguments, "body"),
         marker <- optional_string(arguments, "marker") || Config.workpad_marker(),
         {:ok, result} <- tracker_call(tracker, :upsert_workpad_comment, [issue_id, body, [marker: marker]]) do
      {:ok, result}
    end
  end

  defp run_linear_workflow_action("transition_issue", arguments, tracker) do
    with {:ok, issue_id} <- required_string(arguments, "issueId"),
         {:ok, state_role} <- required_string(arguments, "stateRole"),
         :ok <- tracker_call(tracker, :transition_issue, [issue_id, state_role]) do
      {:ok, %{"issueId" => issue_id, "stateRole" => state_role}}
    end
  end

  defp run_linear_workflow_action("attach_external_link", arguments, tracker) do
    with {:ok, issue_id} <- required_string(arguments, "issueId"),
         {:ok, title} <- required_string(arguments, "title"),
         {:ok, url} <- required_string(arguments, "url"),
         :ok <- tracker_call(tracker, :attach_external_link, [issue_id, %{"title" => title, "url" => url}]) do
      {:ok, %{"issueId" => issue_id, "title" => title, "url" => url}}
    end
  end

  defp run_linear_workflow_action("create_issue", arguments, tracker) do
    with {:ok, title} <- required_string(arguments, "title"),
         {:ok, attrs} <- build_issue_create_attrs(arguments, title),
         {:ok, created_issue} <- tracker_call(tracker, :create_issue, [attrs]) do
      {:ok, created_issue}
    end
  end

  defp run_linear_workflow_action("create_followup_issue", arguments, tracker) do
    with {:ok, issue_id} <- required_string(arguments, "issueId"),
         {:ok, title} <- required_string(arguments, "title"),
         {:ok, issue} <- tracker_call(tracker, :fetch_issue, [issue_id]),
         attrs <- %{
           "current_issue_id" => issue_id,
           "title" => title,
           "description" => optional_string(arguments, "description"),
           "team_id" => Map.get(issue, :team_id),
           "project_id" => optional_string(arguments, "projectId") || Map.get(issue, :project_id),
           "state_id" => optional_string(arguments, "stateId"),
           "state_name" => optional_string(arguments, "stateName") || Config.lifecycle_state(:backlog),
           "relation_type" => optional_string(arguments, "relationType") || "related"
         },
         {:ok, created_issue} <- tracker_call(tracker, :create_related_issue, [attrs]) do
      {:ok, created_issue}
    end
  end

  defp run_linear_workflow_action(action, _arguments, _tracker),
    do: {:error, {:unsupported_linear_workflow_action, action}}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp build_issue_create_attrs(arguments, title) do
    attrs = %{
      "title" => title,
      "description" => optional_string(arguments, "description"),
      "team_id" => optional_string(arguments, "teamId"),
      "project_id" => optional_string(arguments, "projectId"),
      "state_id" => optional_string(arguments, "stateId"),
      "state_name" => optional_string(arguments, "stateName"),
      "current_issue_id" => optional_string(arguments, "currentIssueId")
    }

    if attrs["team_id"] || attrs["current_issue_id"] do
      {:ok, attrs}
    else
      {:error, :missing_issue_creation_context}
    end
  end

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_linear_workflow_arguments) do
    %{
      "error" => %{
        "message" => "`linear_workflow` expects an object with an `action` field."
      }
    }
  end

  defp tool_error_payload(:missing_issue_creation_context) do
    %{
      "error" => %{
        "message" =>
          "`linear_workflow.create_issue` requires either `teamId` or `currentIssueId` so Symphony can resolve the target team."
      }
    }
  end

  defp tool_error_payload(:missing_issue_title) do
    %{
      "error" => %{
        "message" => "`linear_workflow.create_issue` requires a non-empty `title`."
      }
    }
  end

  defp tool_error_payload(:missing_issue_team_id) do
    %{
      "error" => %{
        "message" => "Symphony could not resolve the Linear team for the new issue."
      }
    }
  end

  defp tool_error_payload({:missing_required_argument, field}) do
    %{
      "error" => %{
        "message" => "`#{field}` is required and must be a non-empty string."
      }
    }
  end

  defp tool_error_payload({:unsupported_linear_workflow_action, action}) do
    %{
      "error" => %{
        "message" => "Unsupported `linear_workflow` action: #{inspect(action)}."
      }
    }
  end

  defp tool_error_payload({:missing_tracker_callback, fun}) do
    %{
      "error" => %{
        "message" =>
          "The configured tracker does not implement the required callback for `linear_workflow`.",
        "callback" => to_string(fun)
      }
    }
  end

  defp tool_error_payload({:unknown_lifecycle_role, state_role}) do
    %{
      "error" => %{
        "message" => "Unknown lifecycle role for `linear_workflow.transition_issue`.",
        "stateRole" => inspect(state_role)
      }
    }
  end

  defp tool_error_payload(:invalid_external_link) do
    %{
      "error" => %{
        "message" =>
          "`linear_workflow.attach_external_link` requires non-empty `title` and `url` values."
      }
    }
  end

  defp tool_error_payload(:missing_related_issue_title) do
    %{
      "error" => %{
        "message" => "`linear_workflow.create_followup_issue` requires a non-empty `title`."
      }
    }
  end

  defp tool_error_payload(:missing_related_issue_team_id) do
    %{
      "error" => %{
        "message" => "Symphony could not resolve the Linear team for the follow-up issue."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp required_string(arguments, key) do
    case optional_string(arguments, key) do
      nil -> {:error, {:missing_required_argument, key}}
      value -> {:ok, value}
    end
  end

  defp optional_string(arguments, key) do
    case argument_value(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp argument_value(arguments, key) when is_map(arguments) and is_binary(key) do
    cond do
      Map.has_key?(arguments, key) ->
        Map.get(arguments, key)

      true ->
        Enum.find_value(arguments, fn
          {candidate_key, value} when is_atom(candidate_key) ->
            if Atom.to_string(candidate_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp argument_value(_arguments, _key), do: nil

  defp issue_payload(issue) when is_map(issue) do
    %{
      "id" => Map.get(issue, :id),
      "identifier" => Map.get(issue, :identifier),
      "title" => Map.get(issue, :title),
      "description" => Map.get(issue, :description),
      "state" => Map.get(issue, :state),
      "stateId" => Map.get(issue, :state_id),
      "branchName" => Map.get(issue, :branch_name),
      "url" => Map.get(issue, :url),
      "teamId" => Map.get(issue, :team_id),
      "projectId" => Map.get(issue, :project_id),
      "comments" => Map.get(issue, :comments, []),
      "attachments" => Map.get(issue, :attachments, []),
      "stateNodes" => Map.get(issue, :state_nodes, []),
      "labels" => Map.get(issue, :labels, []),
      "blockedBy" => Map.get(issue, :blocked_by, [])
    }
  end

  defp tracker_call(tracker, fun, args) when is_atom(tracker) do
    apply(tracker, fun, args)
  end

  defp tracker_call(tracker, fun, args) when is_map(tracker) do
    case Map.get(tracker, fun) do
      callback when is_function(callback, length(args)) -> apply(callback, args)
      _ -> {:error, {:missing_tracker_callback, fun}}
    end
  end
end
