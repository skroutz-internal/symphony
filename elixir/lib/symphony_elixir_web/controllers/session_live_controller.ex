defmodule SymphonyElixirWeb.SessionLiveController do
  @moduledoc """
  Serves the pre-generated pi session live viewer HTML.

  GET /api/v1/:issue_identifier/session-live

  The template is compiled in at build time from
  priv/static/session-live-template.html (regenerate with
  `node tools/generate-session-live-template.mjs` when pi is updated).
  The {{SSE_URL}} placeholder is substituted with the per-issue SSE
  endpoint at request time — no pi runtime dependency.
  """

  use Phoenix.Controller, formats: [:html]

  @template_path "priv/static/session-live-template.html"
  @external_resource @template_path
  @template File.read!(@template_path)

  @sse_url_placeholder "{{SSE_URL}}"

  def show(conn, %{"issue_identifier" => issue_id}) do
    sse_url = "/api/v1/#{issue_id}/stream"
    html = String.replace(@template, @sse_url_placeholder, sse_url)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end
end
