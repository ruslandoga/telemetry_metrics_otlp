defmodule TelemetryMetricsOTLP.Test.EventPlanStorage do
  @moduledoc false

  @behaviour TelemetryMetricsOTLP.Storage

  @impl true
  def init(options) do
    state = Map.new(options)

    handler_count =
      case Map.get(state, :observe_event) do
        nil -> nil
        event_name -> length(:telemetry.list_handlers(event_name))
      end

    notify(state, {:init, self(), handler_count})

    case failure(state, :init) do
      :ok -> {:ok, state}
      result -> result
    end
  end

  @impl true
  def resolve(state) do
    notify(state, {:resolve, self()})
    run_failure(state, :resolve)
    state
  end

  @impl true
  def insert_counter(state, metric_id, tags) do
    notify(state, {:insert_counter, metric_id, tags})
    result(state, {:counter, metric_id})
  end

  @impl true
  def insert_sum(state, metric_id, value, tags) do
    notify(state, {:insert_sum, metric_id, value, tags})
    result(state, {:sum, metric_id})
  end

  @impl true
  def insert_gauge(state, metric_id, value, tags) do
    notify(state, {:insert_gauge, metric_id, value, tags})
    result(state, {:gauge, metric_id})
  end

  @impl true
  def insert_histogram(state, metric_id, value, bucket_index, tags) do
    notify(state, {:insert_histogram, metric_id, value, bucket_index, tags})
    result(state, {:histogram, metric_id})
  end

  @impl true
  def record_error(state, metric_id, reason) do
    notify(state, {:record_error, metric_id, reason})
    result(state, :record_error)
  end

  @impl true
  def terminate(state) do
    notify(state, {:terminate, self()})
    run_failure(state, :terminate)
    :ok
  end

  def notify(%{owner: owner, token: token}, event) do
    send(owner, {__MODULE__, token, event})
    :ok
  end

  def handle_event(_event_name, _measurements, _metadata, _config), do: :ok

  defp result(state, key) do
    case failure(state, key) do
      :ok -> :ok
      {:return, value} -> value
      action -> run(action)
    end
  end

  defp run_failure(state, key) do
    case failure(state, key) do
      :ok -> :ok
      {:return, value} -> value
      action -> run(action)
    end
  end

  defp failure(state, key) do
    state
    |> Map.get(:failures, %{})
    |> Map.get(key, :ok)
  end

  defp run({:raise, message}), do: raise(message)
  defp run({:throw, reason}), do: throw(reason)
  defp run({:exit, reason}), do: exit(reason)
end
