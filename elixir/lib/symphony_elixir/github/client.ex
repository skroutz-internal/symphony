defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub REST + GraphQL client for project management operations.
  """

  require Logger

  @graphql_endpoint "https://api.github.com/graphql"
  @rest_base "https://api.github.com"

  @resolve_user_query """
  query ResolveProject($login: String!, $number: Int!) {
    user(login: $login) {
      projectV2(number: $number) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options { id name }
          }
        }
      }
    }
  }
  """

  @resolve_org_query """
  query ResolveProjectOrg($login: String!, $number: Int!) {
    organization(login: $login) {
      projectV2(number: $number) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options { id name }
          }
        }
      }
    }
  }
  """

  @fetch_items_query """
  query FetchProjectItems($projectId: ID!, $cursor: String) {
    node(id: $projectId) {
      ... on ProjectV2 {
        items(first: 100, after: $cursor) {
          nodes {
            id
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue {
                __typename
                name
              }
            }
            content {
              __typename
              ... on Issue {
                number title body url state
                createdAt updatedAt
                repository {
                  name
                  owner { login }
                }
                labels(first: 20) { nodes { name } }
                assignees(first: 5) { nodes { login } }
              }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @update_status_mutation """
  mutation UpdateItemStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: { singleSelectOptionId: $optionId }
    }) {
      projectV2Item { id }
    }
  }
  """

  @spec auth_headers(String.t()) :: [{String.t(), String.t()}]
  def auth_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"User-Agent", "symphony-elixir"}
    ]
  end

  @spec resolve_project_metadata(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_project_metadata(token, owner_type, owner, project_number, opts \\ []) do
    query = project_query(owner_type)
    vars = %{"login" => owner, "number" => project_number}

    with {:ok, body} <- do_graphql(query, vars, token, opts),
         {:ok, project_node} <- extract_project_node(body, owner_type) do
      {:ok, build_metadata(project_node)}
    else
      :null -> {:error, :project_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_project_items(String.t(), String.t(), String.t(), pos_integer(), keyword(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_project_items(token, owner_type, owner, project_number, fetch_opts \\ [], opts \\ []) do
    with {:ok, meta} <- resolve_project_metadata(token, owner_type, owner, project_number, opts) do
      fetch_items_pages(token, meta.project_id, nil, [], fetch_opts, opts)
    end
  end

  @spec fetch_project_item_by_issue(
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          String.t(),
          pos_integer(),
          keyword()
        ) :: {:ok, map()} | {:error, :not_found} | {:error, term()}
  def fetch_project_item_by_issue(token, owner_type, owner, project_number, repo, issue_number, opts \\ []) do
    with {:ok, items} <- fetch_project_items(token, owner_type, owner, project_number, [], opts) do
      find_item_by_number_and_repo(items, repo, issue_number)
    end
  end

  @spec create_comment(String.t(), String.t(), pos_integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def create_comment(token, repo, issue_number, body, opts \\ []) do
    {owner, repo_name} = parse_repo(repo)
    url = "#{@rest_base}/repos/#{owner}/#{repo_name}/issues/#{issue_number}/comments"
    do_rest(:post, url, %{"body" => body}, token, opts)
  end

  @spec update_item_status(
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          String.t(),
          pos_integer(),
          String.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def update_item_status(token, owner_type, owner, project_number, repo, issue_number, status_name, opts \\ []) do
    with {:ok, meta} <- resolve_project_metadata(token, owner_type, owner, project_number, opts),
         {:ok, option_id} <- find_option_id(meta.status_options, status_name),
         {:ok, item} <-
           fetch_project_item_by_issue(token, owner_type, owner, project_number, repo, issue_number, opts),
         {:ok, _body} <-
           do_graphql(
             @update_status_mutation,
             %{
               "projectId" => meta.project_id,
               "itemId" => item["id"],
               "fieldId" => meta.status_field_id,
               "optionId" => option_id
             },
             token,
             opts
           ) do
      :ok
    end
  end

  @spec close_issue(String.t(), String.t(), pos_integer(), keyword()) ::
          :ok | {:error, term()}
  def close_issue(token, repo, issue_number, opts \\ []) do
    {owner, repo_name} = parse_repo(repo)
    url = "#{@rest_base}/repos/#{owner}/#{repo_name}/issues/#{issue_number}"
    do_rest(:patch, url, %{"state" => "closed"}, token, opts)
  end

  defp project_query("user"), do: @resolve_user_query
  defp project_query("org"), do: @resolve_org_query
  defp project_query(_owner_type), do: @resolve_org_query

  defp extract_project_node(%{"data" => data}, "user") when is_map(data) do
    case get_in(data, ["user", "projectV2"]) do
      nil -> :null
      project -> {:ok, project}
    end
  end

  defp extract_project_node(%{"data" => data}, "org") when is_map(data) do
    case get_in(data, ["organization", "projectV2"]) do
      nil -> :null
      project -> {:ok, project}
    end
  end

  defp extract_project_node(_body, _owner_type), do: :null

  defp build_metadata(project_node) do
    options =
      project_node
      |> get_in(["field", "options"])
      |> List.wrap()
      |> Enum.reduce(%{}, fn opt, acc -> Map.put(acc, opt["name"], opt["id"]) end)

    %{
      project_id: project_node["id"],
      status_field_id: get_in(project_node, ["field", "id"]),
      status_options: options,
      status_option_names:
        project_node
        |> get_in(["field", "options"])
        |> List.wrap()
        |> Enum.map(& &1["name"])
        |> Enum.filter(&is_binary/1)
    }
  end

  defp find_item_by_number_and_repo(items, repo, issue_number) do
    case Enum.find(items, fn item ->
           get_in(item, ["content", "number"]) == issue_number and item_repo(item) == repo
         end) do
      nil -> {:error, :not_found}
      item -> {:ok, item}
    end
  end

  defp item_repo(item) do
    owner = get_in(item, ["content", "repository", "owner", "login"])
    name = get_in(item, ["content", "repository", "name"])

    if is_binary(owner) and is_binary(name), do: "#{owner}/#{name}", else: nil
  end

  defp fetch_items_pages(token, project_id, cursor, acc, fetch_opts, opts) do
    vars = %{"projectId" => project_id, "cursor" => cursor}

    with {:ok, body} <- do_graphql(@fetch_items_query, vars, token, opts) do
      items = get_in(body, ["data", "node", "items", "nodes"]) || []
      page_info = get_in(body, ["data", "node", "items", "pageInfo"]) || %{}
      has_next = page_info["hasNextPage"] == true
      end_cursor = page_info["endCursor"]

      filtered = filter_items_by_states(items, fetch_opts[:states])
      updated_acc = acc ++ filtered

      if has_next and is_binary(end_cursor) do
        fetch_items_pages(token, project_id, end_cursor, updated_acc, fetch_opts, opts)
      else
        {:ok, updated_acc}
      end
    end
  end

  defp filter_items_by_states(items, nil), do: items

  defp filter_items_by_states(items, states) when is_list(states) do
    normalized = Enum.map(states, &normalize_state/1)

    Enum.filter(items, fn item ->
      status = get_in(item, ["fieldValueByName", "name"])
      is_binary(status) and normalize_state(status) in normalized
    end)
  end

  defp find_option_id(status_options, status_name) do
    normalized_state_name = normalize_state(status_name)

    case Enum.find(status_options, fn {name, _id} -> normalize_state(name) == normalized_state_name end) do
      {_, id} -> {:ok, id}
      nil -> {:error, :status_option_not_found}
    end
  end

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp do_graphql(query, variables, token, opts) do
    default_fun =
      Application.get_env(
        :symphony_elixir,
        :github_graphql_request_fun,
        fn q, v, t ->
          Req.post(@graphql_endpoint,
            headers: auth_headers(t),
            json: %{"query" => q, "variables" => v},
            connect_options: [timeout: 30_000]
          )
        end
      )

    request_fun = Keyword.get(opts, :graphql_request_fun, default_fun)

    Logger.debug("GitHub GraphQL request, query_head=#{String.slice(query, 0, 60)}")

    case request_fun.(query, variables, token) do
      {:ok, %{status: 200, body: %{"errors" => errors} = body}} when is_list(errors) ->
        {:error, {:github_graphql_errors, errors, body}}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("GitHub GraphQL OK")
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.warning("GitHub GraphQL status=#{status}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        Logger.warning("GitHub GraphQL error reason=#{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp do_rest(method, url, body, token, opts) do
    default_fun =
      Application.get_env(
        :symphony_elixir,
        :github_rest_request_fun,
        fn m, u, b, h ->
          apply(Req, m, [u, [headers: h, json: b, connect_options: [timeout: 30_000]]])
        end
      )

    request_fun = Keyword.get(opts, :rest_request_fun, default_fun)

    case request_fun.(method, url, body, auth_headers(token)) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp parse_repo(repo) do
    case String.split(repo, "/") do
      [owner, repo_name] -> {owner, repo_name}
      _ -> raise ArgumentError, "invalid repo format: #{repo}"
    end
  end
end
