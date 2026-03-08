defmodule SymphonyElixir.GitHub.IssueMapper do
  @moduledoc """
  Converts GitHub Projects v2 item JSON into `%SymphonyElixir.Linear.Issue{}` structs.
  """

  alias SymphonyElixir.Linear.Issue

  @max_branch_bytes 80

  @spec from_project_item(map(), keyword()) :: Issue.t() | nil
  def from_project_item(item, opts \\ []) do
    content = item["content"]

    case content["__typename"] do
      "Issue" -> build_issue(item, content, opts)
      _other -> nil
    end
  end

  @spec branch_name(integer(), String.t()) :: String.t()
  def branch_name(number, title) do
    prefix = "#{number}-"

    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    full = prefix <> slug

    if byte_size(full) <= @max_branch_bytes do
      full
    else
      full
      |> String.slice(0, @max_branch_bytes)
      |> String.trim_trailing("-")
    end
  end

  # -- private ----------------------------------------------------------------

  defp build_issue(item, content, opts) do
    with repo when is_binary(repo) <- extract_repo(content),
         number when is_integer(number) <- content["number"] do
      assignee_filter = Keyword.get(opts, :assignee_filter)
      assignees = get_in(content, ["assignees", "nodes"]) || []
      identifier = "#{repo}##{number}"

      %Issue{
        id: identifier,
        identifier: identifier,
        title: content["title"],
        description: content["body"],
        priority: nil,
        state: extract_state(item),
        branch_name: branch_name(number, content["title"]),
        url: content["url"],
        assignee_id: first_assignee_login(assignees),
        labels: extract_labels(content),
        blocked_by: [],
        assigned_to_worker: assigned_to_worker?(assignees, assignee_filter),
        created_at: parse_datetime(content["createdAt"]),
        updated_at: parse_datetime(content["updatedAt"])
      }
    else
      _ -> nil
    end
  end

  defp extract_repo(content) when is_map(content) do
    case get_in(content, ["repository", "owner", "login"]) do
      owner when is_binary(owner) ->
        case get_in(content, ["repository", "name"]) do
          repo_name when is_binary(repo_name) -> "#{owner}/#{repo_name}"
          _ -> repo_from_url(content["url"])
        end

      _ ->
        repo_from_url(content["url"])
    end
  end

  defp extract_repo(_content), do: nil

  defp repo_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: "github.com", path: path} when is_binary(path) ->
        path
        |> String.trim_leading("/")
        |> String.split("/", parts: 4)
        |> case do
          [owner, repo_name, "issues", _number] when owner != "" and repo_name != "" ->
            "#{owner}/#{repo_name}"

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp repo_from_url(_url), do: nil

  defp extract_state(%{"fieldValueByName" => %{"name" => name}}) when is_binary(name), do: name
  defp extract_state(_item), do: nil

  defp first_assignee_login([%{"login" => login} | _]), do: login
  defp first_assignee_login(_), do: nil

  defp extract_labels(content) do
    (get_in(content, ["labels", "nodes"]) || [])
    |> Enum.map(&String.downcase(&1["name"]))
    |> Enum.uniq()
  end

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, filter) do
    Enum.any?(assignees, fn %{"login" => login} -> login == filter end)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    {:ok, dt, _offset} = DateTime.from_iso8601(str)
    dt
  end
end
