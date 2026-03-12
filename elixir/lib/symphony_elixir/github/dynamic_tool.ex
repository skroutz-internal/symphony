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

  @github_agent_tool "github_agent"
  @github_agent_description """
  Guidance-only fallback for GitHub work. If you think you need this tool, use
  the working `gh` CLI instead. Stay strictly within the configured GitHub
  project and allowed repositories for this run, and do not touch unrelated
  GitHub data.
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

  @spec execute(String.t() | nil, term()) :: map()
  def execute(tool, arguments) do
    case tool do
      @github_agent_tool ->
        execute_github_agent(arguments)

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

  defp failure_response(payload) do
    %{
      "success" => false,
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

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
