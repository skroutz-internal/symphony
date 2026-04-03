defmodule SymphonyElixir.GitHub.ClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.Client

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
                %{"id" => "opt2", "name" => "Done"}
              ]
            }
          }
        }
      }
    }
  end

  defp make_item(number, repo \\ "owner/repo", status \\ "Todo") do
    [owner, name] = String.split(repo, "/", parts: 2)

    %{
      "id" => "item_#{number}",
      "fieldValueByName" => %{
        "__typename" => "ProjectV2ItemFieldSingleSelectValue",
        "name" => status,
        "field" => %{"id" => "PVTSSF_x"}
      },
      "content" => %{
        "__typename" => "Issue",
        "number" => number,
        "title" => "Issue #{number}",
        "body" => "body",
        "url" => "https://github.com/#{repo}/issues/#{number}",
        "repository" => %{"name" => name, "owner" => %{"login" => owner}},
        "state" => "OPEN",
        "createdAt" => "2024-01-01T00:00:00Z",
        "updatedAt" => "2024-01-01T00:00:00Z",
        "labels" => %{"nodes" => []},
        "assignees" => %{"nodes" => []}
      }
    }
  end

  defp items_response(items, has_next_page, end_cursor \\ nil) do
    %{
      "data" => %{
        "node" => %{
          "items" => %{
            "nodes" => items,
            "pageInfo" => %{
              "hasNextPage" => has_next_page,
              "endCursor" => end_cursor
            }
          }
        }
      }
    }
  end

  defp graphql_mock(fun) do
    Application.put_env(:symphony_elixir, :github_graphql_request_fun, fun)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_graphql_request_fun) end)
  end

  defp rest_mock(fun) do
    Application.put_env(:symphony_elixir, :github_rest_request_fun, fun)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_rest_request_fun) end)
  end

  defp metadata_and_items_mock(owner_type, items) do
    fn _q, v, _t ->
      if Map.has_key?(v, "projectId") do
        {:ok, %{status: 200, body: items_response(items, false)}}
      else
        {:ok, %{status: 200, body: project_metadata_response(owner_type)}}
      end
    end
  end

  describe "auth_headers/1" do
    test "includes Authorization and Accept headers" do
      headers = Client.auth_headers("ghp_abc")
      assert {"Authorization", "Bearer ghp_abc"} in headers
      assert {"Accept", "application/vnd.github+json"} in headers
    end
  end

  describe "resolve_project_metadata/5" do
    test "returns project metadata from user query" do
      result =
        Client.resolve_project_metadata("tok", "user", "owner", 1,
          graphql_request_fun: fn _q, _v, _t ->
            {:ok, %{status: 200, body: project_metadata_response("user")}}
          end
        )

      assert {:ok,
              %{
                project_id: "PVT_x",
                status_field_id: "PVTSSF_x",
                status_options: %{"Todo" => "opt1", "Done" => "opt2"},
                status_option_names: ["Todo", "Done"]
              }} = result
    end

    test "returns project metadata from org query" do
      result =
        Client.resolve_project_metadata("tok", "org", "owner", 1,
          graphql_request_fun: fn query, _v, _t ->
            assert query =~ "organization(login:"
            {:ok, %{status: 200, body: project_metadata_response("organization")}}
          end
        )

      assert {:ok, %{project_id: "PVT_x"}} = result
    end

    test "returns project_not_found when project is null" do
      result =
        Client.resolve_project_metadata("tok", "user", "owner", 1,
          graphql_request_fun: fn _q, _v, _t ->
            {:ok, %{status: 200, body: %{"data" => %{"user" => %{"projectV2" => nil}}}}}
          end
        )

      assert {:error, :project_not_found} = result
    end

    test "uses Application env mock when no opts given" do
      graphql_mock(fn _q, _v, _t ->
        {:ok, %{status: 200, body: project_metadata_response("user")}}
      end)

      assert {:ok, %{project_id: "PVT_x"}} =
               Client.resolve_project_metadata("tok", "user", "owner", 1)
    end
  end

  describe "fetch_project_items/4" do
    test "returns items for a single page" do
      items = [make_item(1), make_item(2)]

      result =
        Client.fetch_project_items("tok", "org", "acme", 1, [], graphql_request_fun: metadata_and_items_mock("organization", items))

      assert {:ok, fetched} = result
      assert length(fetched) == 2
    end

    test "paginates across multiple pages" do
      calls = :counters.new(1, [])

      result =
        Client.fetch_project_items("tok", "user", "owner", 1, [],
          graphql_request_fun: fn _q, v, _t ->
            if Map.has_key?(v, "projectId") do
              count = :counters.get(calls, 1)
              :counters.add(calls, 1, 1)

              if count == 0 do
                {:ok, %{status: 200, body: items_response([make_item(1), make_item(2)], true, "cur1")}}
              else
                {:ok, %{status: 200, body: items_response([make_item(3)], false)}}
              end
            else
              {:ok, %{status: 200, body: project_metadata_response("user")}}
            end
          end
        )

      assert {:ok, fetched} = result
      assert length(fetched) == 3
      assert :counters.get(calls, 1) == 2
    end

    test "filters items by states opt using trimmed case-insensitive matching" do
      items = [make_item(1, "owner/repo", "Todo"), make_item(2, "owner/repo", "Done")]

      result =
        Client.fetch_project_items("tok", "user", "owner", 1, [states: [" todo "]], graphql_request_fun: metadata_and_items_mock("user", items))

      assert {:ok, [item]} = result
      assert get_in(item, ["fieldValueByName", "name"]) == "Todo"
    end

    test "uses Application env mock when called with 4 args" do
      graphql_mock(metadata_and_items_mock("user", [make_item(1)]))
      assert {:ok, [_]} = Client.fetch_project_items("tok", "user", "owner", 1)
    end
  end

  describe "fetch_project_item_by_issue/6" do
    test "returns item matching issue number and repo" do
      items = [make_item(1), make_item(2, "owner/other"), make_item(2)]

      result =
        Client.fetch_project_item_by_issue("tok", "user", "owner", 1, "owner/repo", 2, graphql_request_fun: metadata_and_items_mock("user", items))

      assert {:ok, item} = result
      assert get_in(item, ["content", "number"]) == 2
      assert get_in(item, ["content", "repository", "name"]) == "repo"
    end

    test "returns not_found when no matching item" do
      items = [make_item(1), make_item(3)]

      result =
        Client.fetch_project_item_by_issue("tok", "user", "owner", 1, "owner/repo", 99, graphql_request_fun: metadata_and_items_mock("user", items))

      assert {:error, :not_found} = result
    end

    test "uses Application env mock when called with 6 args" do
      graphql_mock(metadata_and_items_mock("user", [make_item(42)]))
      assert {:ok, _} = Client.fetch_project_item_by_issue("tok", "user", "owner", 1, "owner/repo", 42)
    end
  end

  describe "create_comment/4" do
    test "posts to REST and returns :ok on 201" do
      result =
        Client.create_comment("ghp_token", "owner/repo", 42, "Hello",
          rest_request_fun: fn :post, url, body, _headers ->
            assert url =~ "/repos/owner/repo/issues/42/comments"
            assert body == %{"body" => "Hello"}
            {:ok, %{status: 201, body: %{}}}
          end
        )

      assert result == :ok
    end

    test "returns error on 403" do
      result =
        Client.create_comment("ghp_token", "owner/repo", 42, "Hello",
          rest_request_fun: fn :post, _url, _body, _headers ->
            {:ok, %{status: 403, body: %{}}}
          end
        )

      assert {:error, {:github_api_status, 403}} = result
    end

    test "uses Application env mock when called with 4 args" do
      rest_mock(fn :post, _url, _body, _headers -> {:ok, %{status: 201, body: %{}}} end)
      assert :ok = Client.create_comment("ghp_token", "owner/repo", 42, "Hello")
    end
  end

  describe "update_item_status/7" do
    test "resolves metadata, finds item, runs mutation" do
      result =
        Client.update_item_status("tok", "user", "owner", 1, "owner/repo", 42, "Todo",
          graphql_request_fun: fn _q, v, _t ->
            cond do
              Map.has_key?(v, "login") ->
                {:ok, %{status: 200, body: project_metadata_response("user")}}

              Map.has_key?(v, "itemId") ->
                {:ok,
                 %{
                   status: 200,
                   body: %{
                     "data" => %{
                       "updateProjectV2ItemFieldValue" => %{
                         "projectV2Item" => %{"id" => "item_42"}
                       }
                     }
                   }
                 }}

              true ->
                {:ok, %{status: 200, body: items_response([make_item(42)], false)}}
            end
          end
        )

      assert result == :ok
    end

    test "matches status option case-insensitively" do
      result =
        Client.update_item_status("tok", "user", "owner", 1, "owner/repo", 42, " done ",
          graphql_request_fun: fn _q, v, _t ->
            cond do
              Map.has_key?(v, "login") ->
                {:ok, %{status: 200, body: project_metadata_response("user")}}

              Map.has_key?(v, "itemId") ->
                assert v["optionId"] == "opt2"
                {:ok, %{status: 200, body: %{"data" => %{}}}}

              true ->
                {:ok, %{status: 200, body: items_response([make_item(42)], false)}}
            end
          end
        )

      assert result == :ok
    end

    test "returns status_option_not_found for unknown status" do
      result =
        Client.update_item_status("tok", "user", "owner", 1, "owner/repo", 42, "NonExistent",
          graphql_request_fun: fn _q, v, _t ->
            if Map.has_key?(v, "login") do
              {:ok, %{status: 200, body: project_metadata_response("user")}}
            else
              {:ok, %{status: 200, body: items_response([make_item(42)], false)}}
            end
          end
        )

      assert {:error, :status_option_not_found} = result
    end

    test "uses Application env mock when called with 7 args" do
      graphql_mock(fn _q, v, _t ->
        cond do
          Map.has_key?(v, "login") ->
            {:ok, %{status: 200, body: project_metadata_response("user")}}

          Map.has_key?(v, "itemId") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "item_1"}}
                 }
               }
             }}

          true ->
            {:ok, %{status: 200, body: items_response([make_item(1)], false)}}
        end
      end)

      assert :ok = Client.update_item_status("tok", "user", "owner", 1, "owner/repo", 1, "Todo")
    end
  end

  describe "close_issue/3" do
    test "patches issue state to closed and returns :ok" do
      result =
        Client.close_issue("ghp_token", "owner/repo", 7,
          rest_request_fun: fn :patch, url, body, _headers ->
            assert url =~ "/repos/owner/repo/issues/7"
            assert body == %{"state" => "closed"}
            {:ok, %{status: 200, body: %{}}}
          end
        )

      assert result == :ok
    end

    test "returns error on 404" do
      result =
        Client.close_issue("ghp_token", "owner/repo", 7,
          rest_request_fun: fn :patch, _url, _body, _headers ->
            {:ok, %{status: 404, body: %{}}}
          end
        )

      assert {:error, {:github_api_status, 404}} = result
    end

    test "uses Application env mock when called with 3 args" do
      rest_mock(fn :patch, _url, _body, _headers -> {:ok, %{status: 200, body: %{}}} end)
      assert :ok = Client.close_issue("ghp_token", "owner/repo", 7)
    end
  end

  describe "error branches" do
    test "graphql request returning non-200 status returns api_status error" do
      result =
        Client.resolve_project_metadata("tok", "user", "owner", 1, graphql_request_fun: fn _q, _v, _t -> {:ok, %{status: 401, body: %{}}} end)

      assert {:error, {:github_api_status, 401}} = result
    end

    test "graphql request returning error tuple returns api_request error" do
      result =
        Client.resolve_project_metadata("tok", "user", "owner", 1, graphql_request_fun: fn _q, _v, _t -> {:error, %{reason: :econnrefused}} end)

      assert {:error, {:github_api_request, _}} = result
    end

    test "graphql 200 response with errors key returns graphql_errors error" do
      errors = [%{"message" => "Field 'id' doesn't exist on type 'ProjectV2ItemFieldSingleSelectValue'"}]

      result =
        Client.resolve_project_metadata("tok", "user", "owner", 1, graphql_request_fun: fn _q, _v, _t -> {:ok, %{status: 200, body: %{"errors" => errors}}} end)

      assert {:error, {:github_graphql_errors, ^errors, _body}} = result
    end

    test "parse_repo raises on invalid format" do
      assert_raise ArgumentError, ~r/invalid repo format/, fn ->
        Client.create_comment("tok", "badformat", 1, "body", rest_request_fun: fn _, _, _, _ -> {:ok, %{status: 201, body: %{}}} end)
      end
    end
  end
end
