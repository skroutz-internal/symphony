defmodule SymphonyElixir.GitHub.DynamicTool do
  @moduledoc """
  Execution engine for GitHub dynamic tools exposed through the pi-agent
  integration.

  The `github_agent` tool is intentionally a failing guidance tool: it nudges
  the model toward the already-available `gh` CLI while reinforcing the rule
  that GitHub operations must stay within the configured project/repository
  scope for the current run.
  """

  use SymphonyElixir.GitHub.PushToSymphonyMixin

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.GitHub.Client

  @github_agent_tool "github_agent"
  @github_project_get_status_options_tool "github_project_get_status_options"
  @github_project_get_current_item_tool "github_project_get_current_item"
  @github_project_move_current_item_tool "github_project_move_current_item"

  @github_agent_description """
  Guidance-only fallback for GitHub work. If you think you need this tool, use
  the working `gh` CLI instead. Stay strictly within the configured GitHub
  project and allowed repositories for this run, and do not touch unrelated
  GitHub data.
  """
  @github_project_get_status_options_description """
  Get the valid status/column names for the configured GitHub Project workflow.
  Use this before choosing a target project status.
  """
  @github_project_get_current_item_description """
  Get the current GitHub Project item and current status for the issue being
  handled in this run.
  """
  @github_project_move_current_item_description """
  Move the current run's GitHub Project item to a new status. Optionally also
  post a short comment to the current issue.
  """

  @github_agent_guidance_message "You have access to a working gh cli! use that, it should be enough. Stay strictly within the configured GitHub project and allowed repositories for this run."

  @github_agent_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["request"],
    "properties" => %{
      "request" => %{
        "type" => "string",
        "description" => "Natural-language request describing the GitHub task to perform."
      }
    }
  }

  @empty_object_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{}
  }

  @github_project_move_current_item_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["state"],
    "properties" => %{
      "state" => %{
        "type" => "string",
        "description" => "Target project status/column name. Must match one of the values returned by github_project_get_status_options."
      },
      "comment" => %{
        "type" => "string",
        "description" => "Optional short comment to post on the current issue while moving the project item."
      }
    }
  }

  @spec execute(String.t() | nil, term()) :: map()
  def execute(tool, arguments), do: execute(tool, arguments, [])

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @github_agent_tool ->
        execute_github_agent(arguments)

      @github_project_get_status_options_tool ->
        execute_get_status_options(arguments)

      @github_project_get_current_item_tool ->
        execute_get_current_item(arguments, opts)

      @github_project_move_current_item_tool ->
        execute_move_current_item(arguments, opts)

      @push_to_symphony_tool ->
        execute_push_to_symphony(arguments)

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
        "name" => @github_agent_tool,
        "description" => @github_agent_description,
        "inputSchema" => @github_agent_input_schema
      },
      %{
        "name" => @github_project_get_status_options_tool,
        "description" => @github_project_get_status_options_description,
        "inputSchema" => @empty_object_input_schema
      },
      %{
        "name" => @github_project_get_current_item_tool,
        "description" => @github_project_get_current_item_description,
        "inputSchema" => @empty_object_input_schema
      },
      %{
        "name" => @github_project_move_current_item_tool,
        "description" => @github_project_move_current_item_description,
        "inputSchema" => @github_project_move_current_item_input_schema
      },
      push_to_symphony_tool_spec()
    ]
  end

  defp execute_github_agent(arguments) do
    with {:ok, request} <- normalize_github_agent_arguments(arguments) do
      failure_response(%{
        "error" => %{
          "tool" => @github_agent_tool,
          "request" => request,
          "message" => @github_agent_guidance_message
        }
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_get_status_options(arguments) do
    with :ok <- normalize_empty_object_arguments(arguments),
         {:ok, tracker} <- github_tracker_settings(),
         {:ok, meta} <-
           Client.resolve_project_metadata(
             tracker.api_key,
             tracker.project_owner_type,
             tracker.project_owner,
             tracker.project_number
           ) do
      success_response(%{
        "ok" => true,
        "project" => project_payload(tracker),
        "status_options" => Map.get(meta, :status_option_names, [])
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_get_current_item(arguments, opts) do
    with :ok <- normalize_empty_object_arguments(arguments),
         {:ok, tracker} <- github_tracker_settings(),
         {:ok, issue_id, repo, issue_number} <- current_issue_context(opts),
         {:ok, item} <-
           Client.fetch_project_item_by_issue(
             tracker.api_key,
             tracker.project_owner_type,
             tracker.project_owner,
             tracker.project_number,
             repo,
             issue_number
           ) do
      success_response(%{
        "ok" => true,
        "issue_id" => issue_id,
        "project" => project_payload(tracker),
        "item" => %{
          "id" => item["id"],
          "content_type" => get_in(item, ["content", "__typename"]),
          "content_id" => get_in(item, ["content", "id"])
        },
        "status" => get_in(item, ["fieldValueByName", "name"])
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_move_current_item(arguments, opts) do
    with {:ok, state_name, comment} <- normalize_move_current_item_arguments(arguments),
         {:ok, tracker} <- github_tracker_settings(),
         {:ok, issue_id, _repo, _issue_number} <- current_issue_context(opts),
         {:ok, before_item} <- fetch_current_item(tracker, issue_id),
         :ok <- Tracker.update_issue_state(issue_id, state_name),
         {:ok, after_item} <- fetch_current_item(tracker, issue_id) do
      success_response(%{
        "ok" => true,
        "issue_id" => issue_id,
        "from" => get_in(before_item, ["fieldValueByName", "name"]),
        "to" => get_in(after_item, ["fieldValueByName", "name"]),
        "comment" => comment_result(issue_id, comment)
      })
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp comment_result(_issue_id, nil), do: %{"attempted" => false, "posted" => false}

  defp comment_result(issue_id, comment) do
    case Tracker.create_comment(issue_id, comment) do
      :ok ->
        %{"attempted" => true, "posted" => true}

      {:error, reason} ->
        %{"attempted" => true, "posted" => false, "error" => inspect(reason)}
    end
  end

  defp fetch_current_item(tracker, issue_id) do
    with {:ok, repo, issue_number} <- parse_issue_id(issue_id) do
      Client.fetch_project_item_by_issue(
        tracker.api_key,
        tracker.project_owner_type,
        tracker.project_owner,
        tracker.project_number,
        repo,
        issue_number
      )
    end
  end

  defp normalize_empty_object_arguments(nil), do: :ok
  defp normalize_empty_object_arguments(%{}), do: :ok
  defp normalize_empty_object_arguments(_arguments), do: {:error, :invalid_empty_object_arguments}

  defp normalize_github_agent_arguments(arguments) when is_map(arguments) do
    case Map.get(arguments, "request") || Map.get(arguments, :request) do
      request when is_binary(request) ->
        case String.trim(request) do
          "" -> {:error, :missing_request}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_request}
    end
  end

  defp normalize_github_agent_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_move_current_item_arguments(arguments) when is_map(arguments) do
    with {:ok, state_name} <- normalize_state_argument(arguments),
         {:ok, comment} <- normalize_comment_argument(arguments) do
      {:ok, state_name, comment}
    end
  end

  defp normalize_move_current_item_arguments(_arguments), do: {:error, :invalid_move_current_item_arguments}

  defp normalize_state_argument(arguments) do
    case Map.get(arguments, "state") || Map.get(arguments, :state) do
      state when is_binary(state) ->
        case String.trim(state) do
          "" -> {:error, :missing_state}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_state}
    end
  end

  defp normalize_comment_argument(arguments) do
    case Map.get(arguments, "comment") || Map.get(arguments, :comment) do
      nil -> {:ok, nil}
      comment when is_binary(comment) -> {:ok, blank_to_nil(comment)}
      _ -> {:error, :invalid_comment}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp github_tracker_settings do
    tracker = Config.settings!().tracker

    case tracker.kind do
      "github" -> {:ok, tracker}
      other -> {:error, {:unsupported_tracker_kind, other}}
    end
  end

  defp current_issue_context(opts) do
    issue = Keyword.get(opts, :issue)

    issue_id =
      cond do
        is_map(issue) and is_binary(Map.get(issue, :identifier)) -> Map.get(issue, :identifier)
        is_map(issue) and is_binary(Map.get(issue, "identifier")) -> Map.get(issue, "identifier")
        is_map(issue) and is_binary(Map.get(issue, :id)) -> Map.get(issue, :id)
        is_map(issue) and is_binary(Map.get(issue, "id")) -> Map.get(issue, "id")
        true -> nil
      end

    with issue_id when is_binary(issue_id) <- issue_id,
         {:ok, repo, issue_number} <- parse_issue_id(issue_id) do
      {:ok, issue_id, repo, issue_number}
    else
      nil -> {:error, :missing_issue_context}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_issue_id(issue_id) when is_binary(issue_id) do
    case String.split(issue_id, "#", parts: 2) do
      [repo, number_str] when repo != "" and number_str != "" ->
        case Integer.parse(number_str) do
          {number, ""} -> {:ok, repo, number}
          _ -> {:error, :invalid_issue_id}
        end

      _ ->
        {:error, :invalid_issue_id}
    end
  end

  defp project_payload(tracker) do
    %{
      "owner_type" => tracker.project_owner_type,
      "owner" => tracker.project_owner,
      "number" => tracker.project_number
    }
  end

  defp success_response(payload) do
    %{
      "success" => true,
      "output" => encode_payload(payload),
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "output" => encode_payload(payload),
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_request) do
    %{
      "error" => %{
        "message" => "`github_agent` requires a non-empty `request` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`github_agent` expects an object with a required `request` string."
      }
    }
  end

  defp tool_error_payload(:invalid_empty_object_arguments) do
    %{
      "error" => %{
        "message" => "This tool expects an empty object as input."
      }
    }
  end

  defp tool_error_payload(:missing_issue_context) do
    %{
      "error" => %{
        "message" => "This tool requires a current GitHub issue from the active Symphony run."
      }
    }
  end

  defp tool_error_payload(:missing_state) do
    %{
      "error" => %{
        "message" => "`github_project_move_current_item` requires a non-empty `state` string."
      }
    }
  end

  defp tool_error_payload(:invalid_comment) do
    %{
      "error" => %{
        "message" => "`github_project_move_current_item.comment` must be a string when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_move_current_item_arguments) do
    %{
      "error" => %{
        "message" => "`github_project_move_current_item` expects an object with required `state` and optional `comment` string."
      }
    }
  end

  defp tool_error_payload(:invalid_issue_id) do
    %{
      "error" => %{
        "message" => "The current issue identifier is not a valid GitHub issue id like owner/repo#123."
      }
    }
  end

  defp tool_error_payload(:project_not_found) do
    %{
      "error" => %{
        "message" => "Could not resolve the configured GitHub Project v2."
      }
    }
  end

  defp tool_error_payload(:not_found) do
    %{
      "error" => %{
        "message" => "Could not find the current issue in the configured GitHub Project."
      }
    }
  end

  defp tool_error_payload(:status_option_not_found) do
    %{
      "error" => %{
        "message" => "The requested project status is not valid for the configured GitHub Project. Use `github_project_get_status_options` first."
      }
    }
  end

  defp tool_error_payload({:unsupported_tracker_kind, kind}) do
    %{
      "error" => %{
        "message" => "GitHub project tools are only available when tracker.kind is `github`.",
        "tracker_kind" => kind
      }
    }
  end

  defp tool_error_payload({:github_api_status, status}) do
    %{
      "error" => %{
        "message" => "GitHub request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:github_graphql_errors, errors, _body}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL returned errors.",
        "errors" => errors
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "GitHub dynamic tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
