defmodule SymphonyElixir.GitHub.PushToSymphonyMixinTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.DynamicTool

  test "push_to_symphony advertises an empty required parameter list" do
    assert %{"inputSchema" => %{"required" => []}} =
             Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "push_to_symphony"))
  end

  test "push_to_symphony echoes payloads and returns shim synthetic agent-end metadata" do
    response = DynamicTool.execute("push_to_symphony", %{"tools" => [%{"name" => "github_agent"}]})

    assert response["success"] == true

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "payload" => %{"tools" => [%{"name" => "github_agent"}]},
             "shim" => %{"cmd" => "synthetic:agent_end"},
             "tool" => "push_to_symphony"
           }
  end

  test "push_to_symphony rejects non-object payloads" do
    response = DynamicTool.execute("push_to_symphony", "bad")

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`push_to_symphony` expects a JSON object payload."
             }
           }
  end
end
