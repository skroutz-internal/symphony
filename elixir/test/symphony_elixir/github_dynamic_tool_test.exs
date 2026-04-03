defmodule SymphonyElixir.GitHub.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.DynamicTool
  alias SymphonyElixir.Linear.Issue

  defp graphql_mock(fun) do
    Application.put_env(:symphony_elixir, :github_graphql_request_fun, fun)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_graphql_request_fun) end)
  end

  defp rest_mock(fun) do
    Application.put_env(:symphony_elixir, :github_rest_request_fun, fun)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_rest_request_fun) end)
  end

  defp github_issue(issue_id \\ "owner/repo#7") do
    %Issue{
      id: issue_id,
      identifier: issue_id,
      title: "GitHub tracker tools",
      description: "Ensure GitHub tracker exposes GitHub project tools",
      state: "Todo",
      url: "https://github.com/owner/repo/issues/7",
      labels: ["backend"]
    }
  end

  defp project_metadata_response(owner_type) do
    %{
      "data" => %{
        owner_type => %{
          "projectV2" => %{
            "id" => "PVT_x",
            "field" => %{
              "id" => "PVTSSF_x",
              "options" => [
                %{"id" => "opt1", "name" => "Todo"},
                %{"id" => "opt2", "name" => "In Progress"},
                %{"id" => "opt3", "name" => "Human Review"}
              ]
            }
          }
        }
      }
    }
  end

  defp item_response(status) do
    %{
      "data" => %{
        "node" => %{
          "items" => %{
            "nodes" => [
              %{
                "id" => "PVTI_7",
                "fieldValueByName" => %{
                  "__typename" => "ProjectV2ItemFieldSingleSelectValue",
                  "name" => status
                },
                "content" => %{
                  "__typename" => "Issue",
                  "number" => 7,
                  "title" => "Issue 7",
                  "body" => "body",
                  "url" => "https://github.com/owner/repo/issues/7",
                  "repository" => %{"name" => "repo", "owner" => %{"login" => "owner"}},
                  "state" => "OPEN",
                  "createdAt" => "2024-01-01T00:00:00Z",
                  "updatedAt" => "2024-01-01T00:00:00Z",
                  "labels" => %{"nodes" => []},
                  "assignees" => %{"nodes" => []}
                }
              }
            ],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      }
    }
  end

  test "tool_specs advertises GitHub project tools" do
    specs = DynamicTool.tool_specs()
    tool_names = Enum.map(specs, & &1["name"])

    assert "github_agent" in tool_names
    assert "github_project_get_status_options" in tool_names
    assert "github_project_get_current_item" in tool_names
    assert "github_project_move_current_item" in tool_names
    assert "push_to_symphony" in tool_names

    assert %{"inputSchema" => %{"required" => []}} =
             Enum.find(specs, &(&1["name"] == "github_project_get_status_options"))

    assert %{"inputSchema" => %{"required" => []}} =
             Enum.find(specs, &(&1["name"] == "github_project_get_current_item"))
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
    assert "github_project_get_status_options" in supported_tools
    assert "github_project_get_current_item" in supported_tools
    assert "github_project_move_current_item" in supported_tools
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

  test "github_project_get_status_options returns configured project statuses" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_owner_type: "org",
      tracker_project_owner: "acme",
      tracker_project_number: 47,
      tracker_project_repositories: ["owner/repo"],
      tracker_api_token: "token"
    )

    graphql_mock(fn _q, _v, _t ->
      {:ok, %{status: 200, body: project_metadata_response("organization")}}
    end)

    response = DynamicTool.execute("github_project_get_status_options", %{})

    assert response["success"] == true

    assert %{
             "ok" => true,
             "project" => %{"owner" => "acme", "owner_type" => "org", "number" => 47},
             "status_options" => ["Todo", "In Progress", "Human Review"]
           } = Jason.decode!(response["output"])
  end

  test "github_project_get_current_item returns the current issue item from run context" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_owner_type: "org",
      tracker_project_owner: "acme",
      tracker_project_number: 47,
      tracker_project_repositories: ["owner/repo"],
      tracker_api_token: "token"
    )

    graphql_mock(fn _q, variables, _t ->
      if Map.has_key?(variables, "login") do
        {:ok, %{status: 200, body: project_metadata_response("organization")}}
      else
        {:ok, %{status: 200, body: item_response("In Progress")}}
      end
    end)

    response = DynamicTool.execute("github_project_get_current_item", %{}, issue: github_issue())

    assert response["success"] == true

    assert %{
             "ok" => true,
             "issue_id" => "owner/repo#7",
             "item" => %{"id" => "PVTI_7", "content_type" => "Issue", "content_id" => nil},
             "status" => "In Progress"
           } = Jason.decode!(response["output"])
  end

  test "github_project_get_current_item rejects missing issue context" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_owner_type: "org",
      tracker_project_owner: "acme",
      tracker_project_number: 47,
      tracker_project_repositories: ["owner/repo"],
      tracker_api_token: "token"
    )

    response = DynamicTool.execute("github_project_get_current_item", %{})

    assert response["success"] == false

    assert %{
             "error" => %{
               "message" => "This tool requires a current GitHub issue from the active Symphony run."
             }
           } = Jason.decode!(response["output"])
  end

  test "github_project_move_current_item updates status and posts optional comment" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_owner_type: "org",
      tracker_project_owner: "acme",
      tracker_project_number: 47,
      tracker_project_repositories: ["owner/repo"],
      tracker_api_token: "token"
    )

    fetch_counter = :counters.new(1, [])

    graphql_mock(fn _q, variables, _t ->
      cond do
        Map.has_key?(variables, "login") ->
          {:ok, %{status: 200, body: project_metadata_response("organization")}}

        Map.has_key?(variables, "itemId") ->
          assert variables["optionId"] == "opt3"
          {:ok, %{status: 200, body: %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_7"}}}}}}

        true ->
          call_index = :counters.get(fetch_counter, 1)
          :counters.add(fetch_counter, 1, 1)

          status = if call_index == 0, do: "Todo", else: "Human Review"
          {:ok, %{status: 200, body: item_response(status)}}
      end
    end)

    rest_mock(fn :post, url, body, _headers ->
      assert url =~ "/repos/owner/repo/issues/7/comments"
      assert body == %{"body" => "all done!"}
      {:ok, %{status: 201, body: %{}}}
    end)

    response =
      DynamicTool.execute(
        "github_project_move_current_item",
        %{"state" => "Human Review", "comment" => "all done!"},
        issue: github_issue()
      )

    assert response["success"] == true

    assert %{
             "ok" => true,
             "issue_id" => "owner/repo#7",
             "from" => "Todo",
             "to" => "Human Review",
             "comment" => %{"attempted" => true, "posted" => true}
           } = Jason.decode!(response["output"])
  end

  test "github_project_move_current_item treats comment failures as best effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_owner_type: "org",
      tracker_project_owner: "acme",
      tracker_project_number: 47,
      tracker_project_repositories: ["owner/repo"],
      tracker_api_token: "token"
    )

    fetch_counter = :counters.new(1, [])

    graphql_mock(fn _q, variables, _t ->
      cond do
        Map.has_key?(variables, "login") ->
          {:ok, %{status: 200, body: project_metadata_response("organization")}}

        Map.has_key?(variables, "itemId") ->
          {:ok, %{status: 200, body: %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_7"}}}}}}

        true ->
          call_index = :counters.get(fetch_counter, 1)
          :counters.add(fetch_counter, 1, 1)

          status = if call_index == 0, do: "Todo", else: "Human Review"
          {:ok, %{status: 200, body: item_response(status)}}
      end
    end)

    rest_mock(fn :post, _url, _body, _headers ->
      {:ok, %{status: 403, body: %{}}}
    end)

    response =
      DynamicTool.execute(
        "github_project_move_current_item",
        %{"state" => "Human Review", "comment" => "all done!"},
        issue: github_issue()
      )

    assert response["success"] == true

    assert %{
             "comment" => %{
               "attempted" => true,
               "posted" => false,
               "error" => error
             }
           } = Jason.decode!(response["output"])

    assert error =~ "github_api_status"
  end

  test "github_project_move_current_item rejects missing state" do
    response = DynamicTool.execute("github_project_move_current_item", %{}, issue: github_issue())

    assert response["success"] == false

    assert %{
             "error" => %{
               "message" => "`github_project_move_current_item` requires a non-empty `state` string."
             }
           } = Jason.decode!(response["output"])
  end
end
