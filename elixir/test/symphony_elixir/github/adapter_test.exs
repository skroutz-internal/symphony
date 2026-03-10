defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter
  alias SymphonyElixir.Linear.Issue

  defmodule FakeGitHubClient do
    @moduledoc false

    def fetch_project_items(_token, _owner_type, _owner, _project_number, _opts \\ []) do
      case Process.get(:fake_fetch_project_items) do
        fun when is_function(fun, 0) -> fun.()
        result -> result
      end
    end

    def fetch_project_item_by_issue(
          _token,
          _owner_type,
          _owner,
          _project_number,
          _repo,
          issue_number,
          _opts \\ []
        ) do
      case Process.get(:fake_fetch_project_item_by_issue) do
        fun when is_function(fun, 1) -> fun.(issue_number)
        result -> result
      end
    end

    def create_comment(_token, _repo, _issue_number, _body, _opts \\ []) do
      case Process.get(:fake_create_comment) do
        fun when is_function(fun, 0) -> fun.()
        result -> result
      end
    end

    def update_item_status(
          _token,
          _owner_type,
          _owner,
          _project_number,
          _repo,
          _issue_number,
          _status_name,
          _opts \\ []
        ) do
      case Process.get(:fake_update_item_status) do
        fun when is_function(fun, 0) -> fun.()
        result -> result
      end
    end

    def close_issue(_token, _repo, _issue_number, _opts \\ []) do
      case Process.get(:fake_close_issue) do
        fun when is_function(fun, 0) -> fun.()
        result -> result
      end
    end
  end

  @project_item_todo %{
    "id" => "PVTI_1",
    "fieldValueByName" => %{
      "__typename" => "ProjectV2ItemFieldSingleSelectValue",
      "name" => "Todo",
      "field" => %{"id" => "F1"}
    },
    "content" => %{
      "__typename" => "Issue",
      "number" => 1,
      "title" => "First",
      "body" => "desc",
      "url" => "https://github.com/owner/repo/issues/1",
      "repository" => %{"name" => "repo", "owner" => %{"login" => "owner"}},
      "state" => "OPEN",
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-01T00:00:00Z",
      "labels" => %{"nodes" => []},
      "assignees" => %{"nodes" => []}
    }
  }

  @project_item_in_progress %{
    "id" => "PVTI_2",
    "fieldValueByName" => %{
      "__typename" => "ProjectV2ItemFieldSingleSelectValue",
      "name" => "In Progress",
      "field" => %{"id" => "F1"}
    },
    "content" => %{
      "__typename" => "Issue",
      "number" => 2,
      "title" => "Second",
      "body" => "desc2",
      "url" => "https://github.com/owner/repo/issues/2",
      "repository" => %{"name" => "repo", "owner" => %{"login" => "owner"}},
      "state" => "OPEN",
      "createdAt" => "2026-01-02T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z",
      "labels" => %{"nodes" => []},
      "assignees" => %{"nodes" => []}
    }
  }

  @project_item_done %{
    "id" => "PVTI_3",
    "fieldValueByName" => %{
      "__typename" => "ProjectV2ItemFieldSingleSelectValue",
      "name" => "Done",
      "field" => %{"id" => "F1"}
    },
    "content" => %{
      "__typename" => "Issue",
      "number" => 3,
      "title" => "Third",
      "body" => "desc3",
      "url" => "https://github.com/owner/repo/issues/3",
      "repository" => %{"name" => "repo", "owner" => %{"login" => "owner"}},
      "state" => "CLOSED",
      "createdAt" => "2026-01-03T00:00:00Z",
      "updatedAt" => "2026-01-03T00:00:00Z",
      "labels" => %{"nodes" => []},
      "assignees" => %{"nodes" => []}
    }
  }

  defp setup_github_workflow(context \\ %{}) do
    overrides =
      Map.get(context, :workflow_overrides, [])
      |> Keyword.merge(
        tracker_kind: "github",
        tracker_project_owner_type: "org",
        tracker_project_owner: "acme",
        tracker_project_number: 1,
        tracker_project_repositories: ["owner/repo"],
        tracker_api_token: "ghp_test"
      )

    write_workflow_file!(Workflow.workflow_file_path(), overrides)
  end

  describe "tracker dispatch" do
    test "Tracker.adapter/0 returns GitHub.Adapter when kind is 'github'" do
      setup_github_workflow()
      assert Tracker.adapter() == SymphonyElixir.GitHub.Adapter
    end
  end

  describe "config validation" do
    test "validates successfully with all required github fields" do
      setup_github_workflow()
      assert :ok = Config.validate!()
    end

    test "rejects missing project owner type" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_project_owner_type: nil,
        tracker_project_owner: "acme",
        tracker_project_number: 1,
        tracker_api_token: "ghp_test"
      )

      assert {:error, :missing_github_project_owner_type} = Config.validate!()
    end

    test "rejects missing project owner" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_project_owner_type: "org",
        tracker_project_owner: nil,
        tracker_project_number: 1,
        tracker_api_token: "ghp_test"
      )

      assert {:error, :missing_github_project_owner} = Config.validate!()
    end

    test "rejects missing project_number" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_project_owner_type: "org",
        tracker_project_owner: "acme",
        tracker_project_number: nil,
        tracker_api_token: "ghp_test"
      )

      assert {:error, :missing_github_project_number} = Config.validate!()
    end

    test "rejects missing api token" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_project_owner_type: "org",
        tracker_project_owner: "acme",
        tracker_project_number: 1,
        tracker_api_token: nil
      )

      assert {:error, :missing_github_api_token} = Config.validate!()
    end

    test "settings expose explicit github project fields" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_project_owner_type: "org",
        tracker_project_owner: "acme",
        tracker_project_number: 7,
        tracker_project_repositories: ["acme/widget"],
        tracker_api_token: "ghp_xxx"
      )

      tracker = Config.settings!().tracker

      assert tracker.kind == "github"
      assert tracker.project_owner_type == "org"
      assert tracker.project_owner == "acme"
      assert tracker.project_number == 7
      assert tracker.project_repositories == ["acme/widget"]
      assert tracker.api_key == "ghp_xxx"
    end
  end

  describe "orchestrator integration" do
    test "GitHub-sourced issues produce valid %Issue{} for dispatch filtering" do
      issue = %Issue{
        id: "owner/repo#42",
        identifier: "owner/repo#42",
        title: "Fix the widget",
        description: "The widget is broken.",
        priority: nil,
        state: "Todo",
        branch_name: "42-fix-the-widget",
        url: "https://github.com/owner/repo/issues/42",
        assignee_id: "octocat",
        labels: ["bug"],
        blocked_by: [],
        assigned_to_worker: true,
        created_at: ~U[2026-01-15 10:00:00Z],
        updated_at: ~U[2026-03-01 14:30:00Z]
      }

      setup_github_workflow()

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        retry_attempts: %{}
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == true
    end

    test "GitHub issue with nil priority is still dispatchable" do
      issue = %Issue{
        id: "owner/repo#10",
        identifier: "owner/repo#10",
        title: "No priority issue",
        description: nil,
        priority: nil,
        state: "In Progress",
        branch_name: "10-no-priority-issue",
        url: "https://github.com/owner/repo/issues/10",
        assignee_id: nil,
        labels: [],
        blocked_by: [],
        assigned_to_worker: true,
        created_at: ~U[2026-02-01 12:00:00Z],
        updated_at: ~U[2026-02-01 12:00:00Z]
      }

      setup_github_workflow()

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        retry_attempts: %{}
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == true
    end

    test "GitHub issue with terminal state is not dispatchable" do
      issue = %Issue{
        id: "owner/repo#5",
        identifier: "owner/repo#5",
        title: "Completed issue",
        description: nil,
        priority: nil,
        state: "Done",
        branch_name: "5-completed-issue",
        url: "https://github.com/owner/repo/issues/5",
        assignee_id: nil,
        labels: [],
        blocked_by: [],
        assigned_to_worker: true,
        created_at: ~U[2026-02-01 12:00:00Z],
        updated_at: ~U[2026-02-01 12:00:00Z]
      }

      setup_github_workflow()

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        retry_attempts: %{}
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == false
    end

    test "GitHub issue with assigned_to_worker=false is not dispatchable" do
      issue = %Issue{
        id: "owner/repo#7",
        identifier: "owner/repo#7",
        title: "Unassigned issue",
        description: nil,
        priority: nil,
        state: "Todo",
        branch_name: "7-unassigned-issue",
        url: "https://github.com/owner/repo/issues/7",
        assignee_id: "other-user",
        labels: [],
        blocked_by: [],
        assigned_to_worker: false,
        created_at: ~U[2026-02-01 12:00:00Z],
        updated_at: ~U[2026-02-01 12:00:00Z]
      }

      setup_github_workflow()

      state = %Orchestrator.State{
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        next_poll_due_at_ms: nil,
        poll_check_in_progress: false,
        running: %{},
        completed: MapSet.new(),
        claimed: MapSet.new(),
        retry_attempts: %{}
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state) == false
    end
  end

  describe "issue sorting" do
    test "issues with nil priority sort after prioritized issues" do
      github_issue = %Issue{
        id: "owner/repo#1",
        identifier: "owner/repo#1",
        title: "GH Issue",
        priority: nil,
        state: "Todo",
        created_at: ~U[2026-01-01 00:00:00Z]
      }

      linear_issue = %Issue{
        id: "lin-1",
        identifier: "SYM-1",
        title: "Linear Issue",
        priority: 2,
        state: "Todo",
        created_at: ~U[2026-01-01 00:00:00Z]
      }

      sorted = Orchestrator.sort_issues_for_dispatch_for_test([github_issue, linear_issue])

      assert hd(sorted).id == "lin-1"
      assert List.last(sorted).id == "owner/repo#1"
    end

    test "issues with same nil priority sort by created_at" do
      older = %Issue{
        id: "owner/repo#1",
        identifier: "owner/repo#1",
        title: "Older",
        priority: nil,
        state: "Todo",
        created_at: ~U[2026-01-01 00:00:00Z]
      }

      newer = %Issue{
        id: "owner/repo#2",
        identifier: "owner/repo#2",
        title: "Newer",
        priority: nil,
        state: "Todo",
        created_at: ~U[2026-02-01 00:00:00Z]
      }

      sorted = Orchestrator.sort_issues_for_dispatch_for_test([newer, older])

      assert hd(sorted).id == "owner/repo#1"
      assert List.last(sorted).id == "owner/repo#2"
    end
  end

  describe "fetch_candidate_issues/0" do
    setup do
      Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
      setup_github_workflow()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_client_module)
      end)

      :ok
    end

    test "returns issues matching active states (Todo, In Progress)" do
      Process.put(:fake_fetch_project_items, {:ok, [@project_item_todo, @project_item_in_progress, @project_item_done]})

      assert {:ok, issues} = Adapter.fetch_candidate_issues()
      assert length(issues) == 2

      states = Enum.map(issues, & &1.state)
      assert "Todo" in states
      assert "In Progress" in states
      refute "Done" in states
    end

    test "filters out issues outside configured project_repositories" do
      other_repo_item =
        put_in(@project_item_todo, ["content", "repository"], %{
          "name" => "other",
          "owner" => %{"login" => "owner"}
        })
        |> put_in(["content", "url"], "https://github.com/owner/other/issues/1")

      Process.put(:fake_fetch_project_items, {:ok, [@project_item_todo, other_repo_item]})

      assert {:ok, issues} = Adapter.fetch_candidate_issues()
      assert Enum.map(issues, & &1.id) == ["owner/repo#1"]
    end

    test "returns empty list when no items match active states" do
      Process.put(:fake_fetch_project_items, {:ok, [@project_item_done]})

      assert {:ok, []} = Adapter.fetch_candidate_issues()
    end

    test "propagates client error" do
      Process.put(:fake_fetch_project_items, {:error, :timeout})

      assert {:error, :timeout} = Adapter.fetch_candidate_issues()
    end

    test "maps items through IssueMapper — returns %Issue{} structs" do
      Process.put(:fake_fetch_project_items, {:ok, [@project_item_todo]})

      assert {:ok, [%Issue{} = issue]} = Adapter.fetch_candidate_issues()
      assert issue.id == "owner/repo#1"
      assert issue.identifier == "owner/repo#1"
      assert issue.title == "First"
      assert issue.state == "Todo"
      assert issue.url == "https://github.com/owner/repo/issues/1"
    end

    test "skips non-Issue content (DraftIssue)" do
      draft_item = %{
        "id" => "PVTI_D1",
        "fieldValueByName" => %{
          "__typename" => "ProjectV2ItemFieldSingleSelectValue",
          "name" => "Todo",
          "field" => %{"id" => "F1"}
        },
        "content" => %{
          "__typename" => "DraftIssue",
          "title" => "Draft thing"
        }
      }

      Process.put(:fake_fetch_project_items, {:ok, [@project_item_todo, draft_item]})

      assert {:ok, issues} = Adapter.fetch_candidate_issues()
      assert length(issues) == 1
      assert hd(issues).title == "First"
    end
  end

  describe "fetch_issues_by_states/1" do
    setup do
      Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
      setup_github_workflow()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_client_module)
      end)

      :ok
    end

    test "filters by given states" do
      Process.put(:fake_fetch_project_items, {:ok, [@project_item_todo, @project_item_in_progress, @project_item_done]})

      assert {:ok, issues} = Adapter.fetch_issues_by_states(["Done"])
      assert length(issues) == 1
      assert hd(issues).state == "Done"
    end

    test "state matching is case-insensitive and trims input" do
      Process.put(:fake_fetch_project_items, {:ok, [@project_item_todo]})

      assert {:ok, [_issue]} = Adapter.fetch_issues_by_states(["todo"])
      assert {:ok, [_issue]} = Adapter.fetch_issues_by_states([" TODO "])
    end

    test "returns empty list when no items match" do
      Process.put(:fake_fetch_project_items, {:ok, [@project_item_todo]})

      assert {:ok, []} = Adapter.fetch_issues_by_states(["Blocked"])
    end

    test "propagates client error" do
      Process.put(:fake_fetch_project_items, {:error, :rate_limited})

      assert {:error, :rate_limited} = Adapter.fetch_issues_by_states(["Todo"])
    end
  end

  describe "fetch_issue_states_by_ids/1" do
    setup do
      Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
      setup_github_workflow()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_client_module)
      end)

      :ok
    end

    test "returns mapped issues for each ID" do
      Process.put(:fake_fetch_project_item_by_issue, fn
        1 -> {:ok, @project_item_todo}
        3 -> {:ok, @project_item_done}
      end)

      assert {:ok, issues} = Adapter.fetch_issue_states_by_ids(["owner/repo#1", "owner/repo#3"])
      assert length(issues) == 2
      assert Enum.at(issues, 0).state == "Todo"
      assert Enum.at(issues, 1).state == "Done"
    end

    test "propagates client error and stops early" do
      Process.put(:fake_fetch_project_item_by_issue, fn _number ->
        {:error, :not_found}
      end)

      assert {:error, :not_found} = Adapter.fetch_issue_states_by_ids(["owner/repo#99"])
    end
  end

  describe "create_comment/2" do
    setup do
      Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
      setup_github_workflow()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_client_module)
      end)

      :ok
    end

    test "delegates to client with parsed issue number" do
      test_pid = self()

      Process.put(:fake_create_comment, fn ->
        send(test_pid, :comment_created)
        :ok
      end)

      assert :ok = Adapter.create_comment("owner/repo#42", "Hello!")
      assert_received :comment_created
    end

    test "propagates client error" do
      Process.put(:fake_create_comment, fn -> {:error, :forbidden} end)

      assert {:error, :forbidden} = Adapter.create_comment("owner/repo#42", "Hello!")
    end
  end

  describe "update_issue_state/2" do
    setup do
      Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
      setup_github_workflow()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :github_client_module)
      end)

      :ok
    end

    test "non-terminal state: updates status only, does NOT close issue" do
      test_pid = self()

      Process.put(:fake_update_item_status, fn ->
        send(test_pid, :status_updated)
        :ok
      end)

      Process.put(:fake_close_issue, fn ->
        send(test_pid, :issue_closed)
        :ok
      end)

      assert :ok = Adapter.update_issue_state("owner/repo#5", "In Progress")
      assert_received :status_updated
      refute_received :issue_closed
    end

    test "terminal state: updates status AND closes issue" do
      test_pid = self()

      Process.put(:fake_update_item_status, fn ->
        send(test_pid, :status_updated)
        :ok
      end)

      Process.put(:fake_close_issue, fn ->
        send(test_pid, :issue_closed)
        :ok
      end)

      assert :ok = Adapter.update_issue_state("owner/repo#5", "Done")
      assert_received :status_updated
      assert_received :issue_closed
    end

    test "terminal state detection is case-insensitive" do
      test_pid = self()

      Process.put(:fake_update_item_status, fn ->
        send(test_pid, :status_updated)
        :ok
      end)

      Process.put(:fake_close_issue, fn ->
        send(test_pid, :issue_closed)
        :ok
      end)

      assert :ok = Adapter.update_issue_state("owner/repo#5", "done")
      assert_received :status_updated
      assert_received :issue_closed
    end

    test "propagates update_item_status error — does NOT call close_issue" do
      test_pid = self()

      Process.put(:fake_update_item_status, fn -> {:error, :mutation_failed} end)

      Process.put(:fake_close_issue, fn ->
        send(test_pid, :issue_closed)
        :ok
      end)

      assert {:error, :mutation_failed} = Adapter.update_issue_state("owner/repo#5", "Done")
      refute_received :issue_closed
    end

    test "propagates close_issue error" do
      Process.put(:fake_update_item_status, fn -> :ok end)
      Process.put(:fake_close_issue, fn -> {:error, :close_failed} end)

      assert {:error, :close_failed} = Adapter.update_issue_state("owner/repo#5", "Closed")
    end
  end
end
