defmodule SymphonyElixirWeb.SessionStreamControllerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HttpServer
  alias SymphonyElixir.StreamBuffer

  setup_all do
    start_supervised!({HttpServer, host: "127.0.0.1", port: 0})
    port = wait_for_bound_port()
    %{port: port}
  end

  setup do
    :ok
  end

  test "connecting client receives buffered events before live stream", %{port: port} do
    issue = "test-issue-#{System.unique_integer([:positive])}"

    events = [
      %{"event" => "frontend_stream", "payload" => %{"method" => "frontend-stream", "params" => %{"type" => "session", "id" => "s1"}}},
      %{"event" => "frontend_stream", "payload" => %{"method" => "frontend-stream", "params" => %{"type" => "message", "id" => "m1"}}},
      %{"event" => "frontend_stream", "payload" => %{"method" => "frontend-stream", "params" => %{"type" => "message", "id" => "m2"}}}
    ]

    Enum.each(events, &StreamBuffer.push(issue, &1))

    received = collect_sse_events("http://127.0.0.1:#{port}/api/v1/#{issue}/stream", length(events))

    assert length(received) == length(events)

    assert Enum.at(received, 0)["payload"]["params"]["id"] == "s1"
    assert Enum.at(received, 1)["payload"]["params"]["id"] == "m1"
    assert Enum.at(received, 2)["payload"]["params"]["id"] == "m2"
  end

  test "late-joining client receives full history including session change", %{port: port} do
    session1 = %{"event" => "frontend_stream", "payload" => %{"method" => "frontend-stream", "params" => %{"type" => "session", "id" => "sess-1"}}}
    msg1     = %{"event" => "frontend_stream", "payload" => %{"method" => "frontend-stream", "params" => %{"type" => "message", "id" => "msg-1", "parentId" => "sess-1"}}}
    session2 = %{"event" => "frontend_stream", "payload" => %{"method" => "frontend-stream", "params" => %{"type" => "session", "id" => "sess-2"}}}
    msg2     = %{"event" => "frontend_stream", "payload" => %{"method" => "frontend-stream", "params" => %{"type" => "message", "id" => "msg-2", "parentId" => "sess-2"}}}

    issue = "test-issue-late-#{System.unique_integer([:positive])}"

    Enum.each([session1, msg1, session2, msg2], &StreamBuffer.push(issue, &1))

    received = collect_sse_events("http://127.0.0.1:#{port}/api/v1/#{issue}/stream", 4)

    ids = Enum.map(received, & get_in(&1, ["payload", "params", "id"]))
    assert ids == ["sess-1", "msg-1", "sess-2", "msg-2"]
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Opens an SSE connection, collects `count` data frames, then closes it.
  defp collect_sse_events(url, count, timeout_ms \\ 3_000) do
    url_charlist = String.to_charlist(url)
    {:ok, request_id} = :httpc.request(:get, {url_charlist, []}, [], sync: false, stream: :self)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    events = do_collect(request_id, count, deadline, [])
    :httpc.cancel_request(request_id)
    events
  end

  defp do_collect(request_id, needed, deadline, acc) do
    if length(acc) >= needed do
      Enum.take(acc, needed)
    else
      wait = max(0, deadline - System.monotonic_time(:millisecond))

      receive do
        {:http, {^request_id, :stream_start, _headers}} ->
          do_collect(request_id, needed, deadline, acc)

        {:http, {^request_id, :stream, chunk}} ->
          do_collect(request_id, needed, deadline, acc ++ parse_sse_chunk(chunk))

        {:http, {^request_id, :stream_end, _headers}} ->
          acc
      after
        wait -> acc
      end
    end
  end

  defp parse_sse_chunk(chunk) when is_binary(chunk) do
    chunk
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      block
      |> String.split("\n")
      |> Enum.find_value(fn
        "data: " <> json -> [Jason.decode!(json)]
        _ -> nil
      end)
      |> List.wrap()
    end)
  end

  defp wait_for_bound_port do
    Enum.find_value(1..40, fn _ ->
      case HttpServer.bound_port() do
        port when is_integer(port) -> port
        _ -> Process.sleep(25) && nil
      end
    end)
  end
end
