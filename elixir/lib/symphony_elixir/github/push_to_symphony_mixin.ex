defmodule SymphonyElixir.GitHub.PushToSymphonyMixin do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @push_to_symphony_tool "push_to_symphony"
      @push_to_symphony_description """
      Send an opaque test/control payload back to Symphony over a generic shim testing channel.
      """
      @push_to_symphony_input_schema %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => true,
        "description" => "Opaque payload forwarded back to Symphony control handlers."
      }

      defp push_to_symphony_tool_spec do
        %{
          "name" => @push_to_symphony_tool,
          "description" => @push_to_symphony_description,
          "inputSchema" => @push_to_symphony_input_schema
        }
      end

      defp execute_push_to_symphony(arguments) when is_map(arguments) do
        payload = %{
          "tool" => @push_to_symphony_tool,
          "payload" => arguments,
          "shim" => %{"cmd" => "synthetic:agent_end"}
        }

        %{
          "success" => true,
          "payload" => arguments,
          "shim" => payload["shim"],
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => Jason.encode!(payload, pretty: true)
            }
          ]
        }
      end

      defp execute_push_to_symphony(_arguments) do
        failure_response(%{
          "error" => %{
            "message" => "`push_to_symphony` expects a JSON object payload."
          }
        })
      end
    end
  end
end
