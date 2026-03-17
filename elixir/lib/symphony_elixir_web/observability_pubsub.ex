defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates and per-issue frontend streams.
  """

  @pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated
  @stream_prefix "frontend_stream:"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec broadcast_update() :: :ok
  def broadcast_update do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, @update_message)

      _ ->
        :ok
    end
  end

  @spec subscribe_stream(String.t()) :: :ok | {:error, term()}
  def subscribe_stream(issue_identifier) when is_binary(issue_identifier) do
    Phoenix.PubSub.subscribe(@pubsub, @stream_prefix <> issue_identifier)
  end

  @spec broadcast_frontend_stream(String.t(), map()) :: :ok
  def broadcast_frontend_stream(issue_identifier, event_data)
      when is_binary(issue_identifier) and is_map(event_data) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          @stream_prefix <> issue_identifier,
          {:frontend_stream, event_data}
        )

      _ ->
        :ok
    end
  end
end
