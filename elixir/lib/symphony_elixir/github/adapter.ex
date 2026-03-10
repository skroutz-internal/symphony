defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter.

  Delegates to a swappable client module (defaults to `SymphonyElixir.GitHub.Client`).
  """

  require Logger

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.IssueMapper

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_and_filter(Config.settings!().tracker.active_states)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    fetch_and_filter(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    tracker = Config.settings!().tracker

    Enum.reduce_while(issue_ids, {:ok, []}, fn issue_id, {:ok, acc} ->
      with {:ok, repo, number} <- parse_issue_id(issue_id),
           {:ok, item} <-
             client_module().fetch_project_item_by_issue(
               tracker.api_key,
               tracker.project_owner_type,
               tracker.project_owner,
               tracker.project_number,
               repo,
               number
             ),
           issue when not is_nil(issue) <-
             IssueMapper.from_project_item(item, assignee_filter: tracker.assignee) do
        {:cont, {:ok, acc ++ [issue]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        nil -> {:cont, {:ok, acc}}
      end
    end)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    tracker = Config.settings!().tracker

    with {:ok, repo, number} <- parse_issue_id(issue_id) do
      client_module().create_comment(tracker.api_key, repo, number, body)
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker
    terminal_states = tracker.terminal_states

    with {:ok, repo, number} <- parse_issue_id(issue_id),
         :ok <-
           client_module().update_item_status(
             tracker.api_key,
             tracker.project_owner_type,
             tracker.project_owner,
             tracker.project_number,
             repo,
             number,
             state_name
           ) do
      if terminal_state?(state_name, terminal_states) do
        client_module().close_issue(tracker.api_key, repo, number)
      else
        :ok
      end
    end
  end

  defp fetch_and_filter(states) do
    tracker = Config.settings!().tracker

    Logger.debug(
      "GitHub fetch_and_filter owner_type=#{tracker.project_owner_type} owner=#{tracker.project_owner} project=#{tracker.project_number} states=#{inspect(states)}"
    )

    with {:ok, items} <-
           client_module().fetch_project_items(
             tracker.api_key,
             tracker.project_owner_type,
             tracker.project_owner,
             tracker.project_number
           ) do
      issues =
        items
        |> Enum.map(&IssueMapper.from_project_item(&1, assignee_filter: tracker.assignee))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&repository_allowed?(&1.id, tracker.project_repositories))
        |> Enum.filter(&state_in?(&1.state, states))

      {:ok, issues}
    end
  end

  defp repository_allowed?(_issue_id, []), do: true

  defp repository_allowed?(issue_id, allowed_repositories) when is_binary(issue_id) do
    case parse_issue_id(issue_id) do
      {:ok, repo, _number} -> repo in allowed_repositories
      {:error, _reason} -> false
    end
  end

  defp repository_allowed?(_issue_id, _allowed_repositories), do: false

  defp state_in?(nil, _states), do: false

  defp state_in?(state, states) when is_list(states) do
    normalized_state = normalize_state(state)
    Enum.any?(states, &(normalize_state(&1) == normalized_state))
  end

  defp terminal_state?(state_name, terminal_states) do
    normalized_state = normalize_state(state_name)
    Enum.any?(terminal_states, &(normalize_state(&1) == normalized_state))
  end

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp parse_issue_id(issue_id) do
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

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, SymphonyElixir.GitHub.Client)
  end
end
