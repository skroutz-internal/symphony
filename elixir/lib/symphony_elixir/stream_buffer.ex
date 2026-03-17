defmodule SymphonyElixir.StreamBuffer do
  @moduledoc """
  Per-task leaky bucket buffer for frontend-stream events.

  Stores up to @max_events events per issue identifier. When the bucket is full
  the oldest event is dropped (leaked), keeping the most recent history.

  With a large enough bucket nothing is dropped in practice; callers that need
  full replay should size the bucket appropriately for their workload.
  """

  use GenServer

  @max_events 2_000
  @name __MODULE__

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: @name)

  @doc "Push an event into the bucket for the given issue."
  @spec push(String.t(), map()) :: :ok
  def push(issue_identifier, event) when is_binary(issue_identifier) and is_map(event) do
    GenServer.cast(@name, {:push, issue_identifier, event})
  end

  @doc "Remove all buffered events for the given issue (call when a task completes)."
  @spec clear(String.t()) :: :ok
  def clear(issue_identifier) when is_binary(issue_identifier) do
    GenServer.cast(@name, {:clear, issue_identifier})
  end

  @doc "Return all buffered events for the issue (oldest first). Does not clear the bucket."
  @spec drain(String.t()) :: [map()]
  def drain(issue_identifier) when is_binary(issue_identifier) do
    GenServer.call(@name, {:drain, issue_identifier})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_cast({:clear, issue}, state) do
    {:noreply, Map.delete(state, issue)}
  end

  @impl true
  def handle_cast({:push, issue, event}, state) do
    bucket = Map.get(state, issue, :queue.new())
    bucket = :queue.in(event, bucket)

    bucket =
      if :queue.len(bucket) > @max_events do
        # Leak the oldest event to make room
        {_, bucket} = :queue.out(bucket)
        bucket
      else
        bucket
      end

    {:noreply, Map.put(state, issue, bucket)}
  end

  @impl true
  def handle_call({:drain, issue}, _from, state) do
    events = state |> Map.get(issue, :queue.new()) |> :queue.to_list()
    {:reply, events, state}
  end
end
