defmodule SymphonyElixir.Codex.NoopDynamicTool do
  @moduledoc """
  Dynamic tool provider used when the configured tracker exposes no dynamic tools.
  """

  @spec tool_specs() :: [map()]
  def tool_specs, do: []

  @spec execute(String.t() | nil, term()) :: map()
  def execute(tool, arguments), do: execute(tool, arguments, [])

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, _arguments, _opts) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" =>
            Jason.encode!(
              %{
                "error" => %{
                  "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
                  "supportedTools" => []
                }
              },
              pretty: true
            )
        }
      ]
    }
  end
end
