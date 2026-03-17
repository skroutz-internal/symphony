defmodule SymphonyElixirWeb.SessionStreamController do
  @moduledoc """
  Server-Sent Events endpoint for live frontend-stream events from a Codex session.

  Clients connect to GET /api/v1/:issue_identifier/stream and receive a stream of
  `data: <json>\\n\\n` frames for every `frontend-stream` message emitted by the
  Codex backend for that issue.
  """

  use Phoenix.Controller, formats: [:html]

  require Logger
  alias Plug.Conn
  alias SymphonyElixirWeb.ObservabilityPubSub

  @keepalive_ms 25_000

  @spec stream(Conn.t(), map()) :: Conn.t()
  def stream(conn, %{"issue_identifier" => issue_identifier}) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache, no-transform")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    :ok = ObservabilityPubSub.subscribe_stream(issue_identifier)
    Logger.debug("SSE client connected for issue=#{issue_identifier}")

    stream_loop(conn, issue_identifier)
  end

  defp stream_loop(conn, issue_identifier) do
    receive do
      {:frontend_stream, event_data} ->
        payload = Jason.encode!(event_data)

        case Conn.chunk(conn, "data: #{payload}\n\n") do
          {:ok, conn} -> stream_loop(conn, issue_identifier)
          {:error, reason} ->
            Logger.debug("SSE client disconnected for issue=#{issue_identifier}: #{inspect(reason)}")
            conn
        end
    after
      @keepalive_ms ->
        case Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_loop(conn, issue_identifier)
          {:error, _} -> conn
        end
    end
  end
end
