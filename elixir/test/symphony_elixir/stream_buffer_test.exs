defmodule SymphonyElixir.StreamBufferTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.StreamBuffer

  setup do
    # Use a unique issue id per test to avoid cross-contamination
    issue = "test-#{System.unique_integer([:positive])}"
    %{issue: issue}
  end

  test "drain returns empty list for unknown issue", %{issue: issue} do
    assert StreamBuffer.drain(issue) == []
  end

  test "push and drain return events in order", %{issue: issue} do
    StreamBuffer.push(issue, %{n: 1})
    StreamBuffer.push(issue, %{n: 2})
    StreamBuffer.push(issue, %{n: 3})

    assert StreamBuffer.drain(issue) == [%{n: 1}, %{n: 2}, %{n: 3}]
  end

  test "drain does not clear the bucket", %{issue: issue} do
    StreamBuffer.push(issue, %{n: 1})

    assert StreamBuffer.drain(issue) == [%{n: 1}]
    assert StreamBuffer.drain(issue) == [%{n: 1}]
  end

  test "separate issues have separate buckets" do
    issue_a = "issue-a-#{System.unique_integer([:positive])}"
    issue_b = "issue-b-#{System.unique_integer([:positive])}"

    StreamBuffer.push(issue_a, %{from: :a})
    StreamBuffer.push(issue_b, %{from: :b})

    assert StreamBuffer.drain(issue_a) == [%{from: :a}]
    assert StreamBuffer.drain(issue_b) == [%{from: :b}]
  end

  test "clear removes all events for the issue", %{issue: issue} do
    StreamBuffer.push(issue, %{n: 1})
    StreamBuffer.push(issue, %{n: 2})

    :ok = StreamBuffer.clear(issue)

    assert StreamBuffer.drain(issue) == []
  end

  test "clear does not affect other issues" do
    issue_a = "issue-a-#{System.unique_integer([:positive])}"
    issue_b = "issue-b-#{System.unique_integer([:positive])}"

    StreamBuffer.push(issue_a, %{n: 1})
    StreamBuffer.push(issue_b, %{n: 2})

    StreamBuffer.clear(issue_a)

    assert StreamBuffer.drain(issue_a) == []
    assert StreamBuffer.drain(issue_b) == [%{n: 2}]
  end

  test "leaky bucket drops oldest events when full", %{issue: issue} do
    # Push max_events + 10 events; oldest 10 should be leaked
    max = 2_000

    for i <- 1..(max + 10) do
      StreamBuffer.push(issue, %{n: i})
    end

    events = StreamBuffer.drain(issue)
    assert length(events) == max
    assert hd(events) == %{n: 11}
    assert List.last(events) == %{n: max + 10}
  end
end
