defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.{LogFile, Tracker}

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @run_switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]

  @issue_create_switches [
    {@acknowledgement_switch, :boolean},
    logs_root: :string,
    workflow: :string,
    title: :string,
    description: :string,
    team_id: :string,
    project_id: :string,
    state_id: :string,
    state_name: :string,
    current_issue_id: :string
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result()),
          create_issue: (map() -> {:ok, map()} | {:error, term()})
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:ok, output} ->
        IO.puts(output)
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:ok, String.t()} | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps())

  def evaluate(["issue", "create" | args], deps) do
    evaluate_issue_create(args, deps)
  end

  def evaluate(args, deps) do
    case OptionParser.parse(args, strict: @run_switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    [
      "Usage:",
      "  symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]",
      "  symphony issue create --title <title> [--team-id <team-id> | --current-issue-id <issue-id>] [--workflow <path>]"
    ]
    |> Enum.join("\n")
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end,
      create_issue: &Tracker.create_issue/1
    }
  end

  defp evaluate_issue_create(args, deps) do
    case OptionParser.parse(args, strict: @issue_create_switches) do
      {opts, positionals, []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             {:ok, workflow_path} <- resolve_issue_create_workflow_path(opts, positionals),
             {:ok, attrs} <- build_issue_create_attrs(opts),
             :ok <- run(workflow_path, deps),
             {:ok, issue} <- deps.create_issue.(attrs) do
          {:ok, Jason.encode!(%{"ok" => true, "issue" => stringify_issue(issue)}, pretty: true)}
        else
          {:error, reason} ->
            {:error, format_issue_create_error(reason)}
        end

      _ ->
        {:error, issue_create_usage_message()}
    end
  end

  defp resolve_issue_create_workflow_path(opts, positionals) do
    workflow_opt = Keyword.get_values(opts, :workflow) |> List.last()

    case {workflow_opt, positionals} do
      {workflow_path, []} when is_binary(workflow_path) ->
        {:ok, workflow_path}

      {nil, []} ->
        {:ok, Path.expand("WORKFLOW.md")}

      {nil, [workflow_path]} ->
        {:ok, workflow_path}

      {workflow_path, [_]} when is_binary(workflow_path) ->
        {:error, issue_create_usage_message()}

      _ ->
        {:error, issue_create_usage_message()}
    end
  end

  defp build_issue_create_attrs(opts) do
    attrs = %{
      "title" => normalize_option_string(Keyword.get_values(opts, :title) |> List.last()),
      "description" => normalize_option_string(Keyword.get_values(opts, :description) |> List.last()),
      "team_id" => normalize_option_string(Keyword.get_values(opts, :team_id) |> List.last()),
      "project_id" => normalize_option_string(Keyword.get_values(opts, :project_id) |> List.last()),
      "state_id" => normalize_option_string(Keyword.get_values(opts, :state_id) |> List.last()),
      "state_name" => normalize_option_string(Keyword.get_values(opts, :state_name) |> List.last()),
      "current_issue_id" => normalize_option_string(Keyword.get_values(opts, :current_issue_id) |> List.last())
    }

    cond do
      attrs["title"] in [nil, ""] ->
        {:error, :missing_issue_title}

      attrs["team_id"] in [nil, ""] and attrs["current_issue_id"] in [nil, ""] ->
        {:error, :missing_issue_creation_context}

      true ->
        {:ok, attrs}
    end
  end

  defp format_issue_create_error(:missing_issue_title) do
    "`issue create` requires `--title <title>`."
  end

  defp format_issue_create_error(:missing_issue_creation_context) do
    "`issue create` requires either `--team-id <team-id>` or `--current-issue-id <issue-id>`."
  end

  defp format_issue_create_error(:missing_issue_team_id),
    do: "Symphony could not resolve the Linear team for the new issue."

  defp format_issue_create_error(:issue_create_failed) do
    "Linear issue creation failed."
  end

  defp format_issue_create_error({:error, reason}), do: format_issue_create_error(reason)
  defp format_issue_create_error(message) when is_binary(message), do: message
  defp format_issue_create_error(reason), do: "Issue creation failed: #{inspect(reason)}"

  defp issue_create_usage_message do
    [
      "Usage:",
      "  symphony issue create --title <title> [--description <body>] [--team-id <team-id> | --current-issue-id <issue-id>]",
      "    [--project-id <project-id>] [--state-id <state-id> | --state-name <state-name>]",
      "    [--workflow <path-to-WORKFLOW.md>] [path-to-WORKFLOW.md]"
    ]
    |> Enum.join("\n")
  end

  defp stringify_issue(issue) when is_map(issue) do
    Map.new(issue, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_option_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_option_string(_value), do: nil

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("-", width + 2)
    top = "+" <> border <> "+"
    bottom = "+" <> border <> "+"
    spacer = "| " <> String.duplicate(" ", width) <> " |"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "| " <> String.pad_trailing(line, width) <> " |"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
