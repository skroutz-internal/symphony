defmodule SymphonyElixir.GitHub.IssueMapperTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.IssueMapper
  alias SymphonyElixir.Linear.Issue

  @github_project_item %{
    "id" => "PVTI_item1",
    "fieldValueByName" => %{
      "__typename" => "ProjectV2ItemFieldSingleSelectValue",
      "name" => "In Progress",
      "field" => %{"id" => "PVTSSF_status1"}
    },
    "content" => %{
      "__typename" => "Issue",
      "number" => 42,
      "title" => "Fix the widget",
      "body" => "The widget is broken.",
      "url" => "https://github.com/owner/repo/issues/42",
      "repository" => %{
        "name" => "repo",
        "owner" => %{"login" => "owner"}
      },
      "state" => "OPEN",
      "createdAt" => "2026-01-15T10:00:00Z",
      "updatedAt" => "2026-03-01T14:30:00Z",
      "labels" => %{"nodes" => [%{"name" => "bug"}, %{"name" => "P1"}]},
      "assignees" => %{"nodes" => [%{"login" => "octocat"}]}
    }
  }

  describe "from_project_item/2" do
    test "T1.1 — maps a full project item to %Issue{}" do
      result = IssueMapper.from_project_item(@github_project_item)

      assert %Issue{} = result
      assert result.id == "owner/repo#42"
      assert result.identifier == "owner/repo#42"
      assert result.title == "Fix the widget"
      assert result.description == "The widget is broken."
      assert result.priority == nil
      assert result.state == "In Progress"
      assert result.branch_name == "42-fix-the-widget"
      assert result.url == "https://github.com/owner/repo/issues/42"
      assert result.assignee_id == "octocat"
      assert result.labels == ["bug", "p1"]
      assert result.blocked_by == []
      assert result.assigned_to_worker == true
      assert result.created_at == ~U[2026-01-15 10:00:00Z]
      assert result.updated_at == ~U[2026-03-01 14:30:00Z]
    end

    test "T1.2 — handles missing optional fields" do
      item = %{
        "id" => "PVTI_item2",
        "fieldValueByName" => nil,
        "content" => %{
          "__typename" => "Issue",
          "number" => 7,
          "title" => "Bare issue",
          "body" => nil,
          "url" => "https://github.com/owner/repo/issues/7",
          "repository" => %{
            "name" => "repo",
            "owner" => %{"login" => "owner"}
          },
          "state" => "OPEN",
          "createdAt" => "2026-01-15T10:00:00Z",
          "updatedAt" => "2026-03-01T14:30:00Z",
          "labels" => %{"nodes" => []},
          "assignees" => %{"nodes" => []}
        }
      }

      result = IssueMapper.from_project_item(item)

      assert %Issue{} = result
      assert result.description == nil
      assert result.state == nil
      assert result.assignee_id == nil
      assert result.labels == []
      assert result.assigned_to_worker == true
    end

    test "T1.3 — skips non-Issue content types" do
      draft_item = put_in(@github_project_item, ["content", "__typename"], "DraftIssue")
      pr_item = put_in(@github_project_item, ["content", "__typename"], "PullRequest")

      assert IssueMapper.from_project_item(draft_item) == nil
      assert IssueMapper.from_project_item(pr_item) == nil
    end

    test "T1.6 — assignee filtering: matched user" do
      result =
        IssueMapper.from_project_item(@github_project_item,
          assignee_filter: "octocat"
        )

      assert result.assigned_to_worker == true
    end

    test "T1.6 — assignee filtering: unmatched user" do
      result =
        IssueMapper.from_project_item(@github_project_item,
          assignee_filter: "other-user"
        )

      assert result.assigned_to_worker == false
    end

    test "T1.6 — assignee filtering: nil filter means always assigned" do
      result =
        IssueMapper.from_project_item(@github_project_item,
          assignee_filter: nil
        )

      assert result.assigned_to_worker == true
    end

    test "T1.7 — labels are lowercased and deduped" do
      item =
        put_in(@github_project_item, ["content", "labels", "nodes"], [
          %{"name" => "Bug"},
          %{"name" => "BUG"},
          %{"name" => "P1"}
        ])

      result = IssueMapper.from_project_item(item)

      assert result.labels == ["bug", "p1"]
    end

    test "T1.8 — falls back to parsing the repo from the issue URL" do
      item = update_in(@github_project_item, ["content"], &Map.delete(&1, "repository"))

      result = IssueMapper.from_project_item(item)

      assert %Issue{} = result
      assert result.id == "owner/repo#42"
      assert result.identifier == "owner/repo#42"
    end
  end

  describe "branch_name/2" do
    test "T1.4 — slug generation with special characters" do
      assert IssueMapper.branch_name(42, "Add SUPER Cool Feature!!  (v2)") ==
               "42-add-super-cool-feature-v2"
    end

    test "T1.5 — truncation for long titles" do
      long_title = String.duplicate("word ", 30)
      result = IssueMapper.branch_name(1, long_title)

      assert byte_size(result) <= 80
      refute String.ends_with?(result, "-")
    end
  end
end
