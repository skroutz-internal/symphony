defmodule SymphonyElixir.GitHub.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.DynamicTool

  test "tool_specs advertises the github_agent input contract and strict fallback guidance" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "request" => _
                 },
                 "required" => ["request"],
                 "type" => "object"
               },
               "name" => "github_agent"
             }
             | _
           ] = DynamicTool.tool_specs()

    assert description =~ "GitHub"
    assert description =~ "gh"
    assert description =~ "configured GitHub"
    assert description =~ "allowed repositories"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => supported_tools
             }
           } = Jason.decode!(text)

    assert "github_agent" in supported_tools
  end

  test "github_agent fails closed and instructs the agent to use gh within scope" do
    response = DynamicTool.execute("github_agent", %{"request" => "open a PR and link the issue"})

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "You have access to a working gh cli! use that, it should be enough. Stay strictly within the configured GitHub project and allowed repositories for this run.",
               "request" => "open a PR and link the issue",
               "tool" => "github_agent"
             }
           }
  end

  test "github_agent trims request strings before returning the fallback guidance" do
    response = DynamicTool.execute("github_agent", %{"request" => "  check the repo status  "})

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "You have access to a working gh cli! use that, it should be enough. Stay strictly within the configured GitHub project and allowed repositories for this run.",
               "request" => "check the repo status",
               "tool" => "github_agent"
             }
           }
  end

  test "github_agent rejects missing request" do
    response = DynamicTool.execute("github_agent", %{})

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`github_agent` requires a non-empty `request` string."
             }
           }
  end

  test "github_agent rejects blank request strings" do
    response = DynamicTool.execute("github_agent", %{"request" => "   "})

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`github_agent` requires a non-empty `request` string."
             }
           }
  end

  test "github_agent rejects invalid argument types" do
    response = DynamicTool.execute("github_agent", "open a PR")

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`github_agent` expects an object with a required `request` string."
             }
           }
  end
end
