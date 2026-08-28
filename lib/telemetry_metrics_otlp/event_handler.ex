defmodule TelemetryMetricsOTLP.EventHandler do
  @moduledoc false

  @compile {:inline, fetch_measurement: 3, keep?: 3}

  require TelemetryMetricsOTLP.Handler.Config
  require TelemetryMetricsOTLP.Handler.Metric

  alias TelemetryMetricsOTLP.Handler.Config
  alias TelemetryMetricsOTLP.Handler.Metric

  @type callback_failure :: {:error | :exit | :throw, term()}

  @type error_reason ::
          {:keep, :invalid_return | callback_failure()}
          | {:measurement, :missing | nil | :not_number | callback_failure()}
          | {:tags, :invalid_return | callback_failure()}
          | {:storage, term() | callback_failure()}

  @type handler_id :: {module(), term(), :telemetry.event_name()}

  @spec attach([{Telemetry.event_name(), Config.t()}], term()) ::
          {:ok, [handler_id()]} | {:error, term()}
  def attach(events, instance_id) do
    Enum.reduce_while(events, {:ok, []}, fn {event_name, config}, {:ok, ids} ->
      handler_id = handler_id(instance_id, event_name)

      case :telemetry.attach(handler_id, event_name, &__MODULE__.handle_event/4, config) do
        :ok ->
          {:cont, {:ok, [handler_id | ids]}}

        {:error, reason} ->
          detach(ids)
          {:halt, {:error, {:attach_failed, event_name, reason}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      {:error, _reason} = error -> error
    end
  end

  @spec detach([handler_id()]) :: :ok
  def detach(handler_ids) do
    Enum.each(handler_ids, &:telemetry.detach/1)
    :ok
  end

  @doc false
  @spec detach_namespace(term()) :: :ok
  def detach_namespace(instance_id) do
    :telemetry.list_handlers([])
    |> Enum.each(fn
      %{id: {__MODULE__, ^instance_id, _event_name} = handler_id} ->
        :telemetry.detach(handler_id)

      _handler ->
        :ok
    end)

    :ok
  end

  @spec handler_id(term(), :telemetry.event_name()) :: handler_id()
  def handler_id(instance_id, event_name) do
    {__MODULE__, instance_id, event_name}
  end

  @spec handle_event(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          Config.t()
        ) :: :ok
  def handle_event(
        _event_name,
        measurements,
        metadata,
        Config.handler_config(
          groups: groups,
          storage_module: storage_module,
          storage: storage,
          record_error: record_error
        )
      ) do
    # Any callback failure must remain local to this handler invocation.
    # `:telemetry` detaches handlers that allow an exception to escape.
    try do
      resolved = storage_module.resolve(storage)
      store_groups(groups, measurements, metadata, resolved, record_error)
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp store_groups([], _measurements, _metadata, _resolved, _record_error), do: :ok

  defp store_groups(
         [{:no_tags, metrics} | rest],
         measurements,
         metadata,
         resolved,
         record_error
       ) do
    store_metrics(metrics, measurements, metadata, resolved, record_error, :no_tags, %{})
    store_groups(rest, measurements, metadata, resolved, record_error)
  end

  defp store_groups(
         [{tag_function, metrics} | rest],
         measurements,
         metadata,
         resolved,
         record_error
       ) do
    store_metrics(
      metrics,
      measurements,
      metadata,
      resolved,
      record_error,
      tag_function,
      :not_computed
    )

    store_groups(rest, measurements, metadata, resolved, record_error)
  end

  defp store_metrics(
         [],
         _measurements,
         _metadata,
         _resolved,
         _record_error,
         _tag_function,
         tag_state
       ),
       do: tag_state

  # Counter/no-keep is the shortest path: its configured measurement is never
  # read or invoked.
  defp store_metrics(
         [
           Metric.handler_metric(
             id: metric_id,
             type: :counter,
             insert: insert,
             keep: :no_keep
           )
           | rest
         ],
         measurements,
         metadata,
         resolved,
         record_error,
         tag_function,
         tag_state
       ) do
    tag_state =
      record_value(
        insert,
        metric_id,
        1,
        metadata,
        resolved,
        record_error,
        tag_function,
        tag_state
      )

    store_metrics(
      rest,
      measurements,
      metadata,
      resolved,
      record_error,
      tag_function,
      tag_state
    )
  end

  defp store_metrics(
         [
           Metric.handler_metric(
             id: metric_id,
             type: :measurement,
             insert: insert,
             keep: :no_keep,
             measurement: measurement
           )
           | rest
         ],
         measurements,
         metadata,
         resolved,
         record_error,
         tag_function,
         tag_state
       ) do
    tag_state =
      case fetch_measurement(measurement, measurements, metadata) do
        value when is_number(value) ->
          record_value(
            insert,
            metric_id,
            value,
            metadata,
            resolved,
            record_error,
            tag_function,
            tag_state
          )

        reason ->
          record_error(record_error, resolved, metric_id, {:measurement, reason})
          tag_state
      end

    store_metrics(
      rest,
      measurements,
      metadata,
      resolved,
      record_error,
      tag_function,
      tag_state
    )
  end

  defp store_metrics(
         [
           Metric.handler_metric(
             id: metric_id,
             type: :counter,
             insert: insert,
             keep: keep
           )
           | rest
         ],
         measurements,
         metadata,
         resolved,
         record_error,
         tag_function,
         tag_state
       ) do
    tag_state =
      case keep?(keep, metadata, measurements) do
        true ->
          record_value(
            insert,
            metric_id,
            1,
            metadata,
            resolved,
            record_error,
            tag_function,
            tag_state
          )

        false ->
          tag_state

        reason ->
          record_error(record_error, resolved, metric_id, {:keep, reason})
          tag_state
      end

    store_metrics(
      rest,
      measurements,
      metadata,
      resolved,
      record_error,
      tag_function,
      tag_state
    )
  end

  defp store_metrics(
         [
           Metric.handler_metric(
             id: metric_id,
             insert: insert,
             keep: keep,
             measurement: measurement
           )
           | rest
         ],
         measurements,
         metadata,
         resolved,
         record_error,
         tag_function,
         tag_state
       ) do
    tag_state =
      case keep?(keep, metadata, measurements) do
        true ->
          case fetch_measurement(measurement, measurements, metadata) do
            value when is_number(value) ->
              record_value(
                insert,
                metric_id,
                value,
                metadata,
                resolved,
                record_error,
                tag_function,
                tag_state
              )

            reason ->
              record_error(record_error, resolved, metric_id, {:measurement, reason})
              tag_state
          end

        false ->
          tag_state

        reason ->
          record_error(record_error, resolved, metric_id, {:keep, reason})
          tag_state
      end

    store_metrics(
      rest,
      measurements,
      metadata,
      resolved,
      record_error,
      tag_function,
      tag_state
    )
  end

  defp record_value(
         insert,
         metric_id,
         value,
         _metadata,
         resolved,
         record_error,
         _tag_function,
         tags
       )
       when is_map(tags) do
    insert(insert, resolved, metric_id, value, tags, record_error)
    tags
  end

  defp record_value(
         _insert,
         metric_id,
         _value,
         _metadata,
         resolved,
         record_error,
         _tag_function,
         {:tag_error, reason} = tag_state
       ) do
    record_error(record_error, resolved, metric_id, {:tags, reason})
    tag_state
  end

  defp record_value(
         insert,
         metric_id,
         value,
         metadata,
         resolved,
         record_error,
         tag_function,
         :not_computed
       ) do
    case extract_tags(tag_function, metadata) do
      tags when is_map(tags) ->
        insert(insert, resolved, metric_id, value, tags, record_error)
        tags

      reason ->
        record_error(record_error, resolved, metric_id, {:tags, reason})
        {:tag_error, reason}
    end
  end

  defp insert(insert, resolved, metric_id, value, tags, record_error) do
    try do
      case insert.(resolved, value, tags) do
        {:error, reason} -> record_error(record_error, resolved, metric_id, {:storage, reason})
        _result -> :ok
      end
    rescue
      exception ->
        record_error(record_error, resolved, metric_id, {:storage, {:error, exception}})
    catch
      kind, reason ->
        record_error(record_error, resolved, metric_id, {:storage, {kind, reason}})
    end
  end

  defp record_error(record_error, resolved, metric_id, reason) do
    try do
      record_error.(resolved, metric_id, reason)
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp keep?({:arity_one, keep}, metadata, _measurements) do
    try do
      case keep.(metadata) do
        result when is_boolean(result) -> result
        _other -> :invalid_return
      end
    rescue
      exception -> {:error, exception}
    catch
      kind, reason -> {kind, reason}
    end
  end

  defp keep?({:arity_two, keep}, metadata, measurements) do
    try do
      case keep.(metadata, measurements) do
        result when is_boolean(result) -> result
        _other -> :invalid_return
      end
    rescue
      exception -> {:error, exception}
    catch
      kind, reason -> {kind, reason}
    end
  end

  defp fetch_measurement({:key, key}, measurements, _metadata) do
    case measurements do
      %{^key => nil} -> nil
      %{^key => value} when is_number(value) -> value
      %{^key => _value} -> :not_number
      %{} -> :missing
      _other -> :not_number
    end
  end

  defp fetch_measurement({:arity_one, measurement}, measurements, _metadata) do
    try do
      case measurement.(measurements) do
        nil -> nil
        value when is_number(value) -> value
        _other -> :not_number
      end
    rescue
      exception -> {:error, exception}
    catch
      kind, reason -> {kind, reason}
    end
  end

  defp fetch_measurement({:arity_two, measurement}, measurements, metadata) do
    try do
      case measurement.(measurements, metadata) do
        nil -> nil
        value when is_number(value) -> value
        _other -> :not_number
      end
    rescue
      exception -> {:error, exception}
    catch
      kind, reason -> {kind, reason}
    end
  end

  defp extract_tags(tag_function, metadata) do
    try do
      case tag_function.(metadata) do
        tags when is_map(tags) -> tags
        _other -> :invalid_return
      end
    rescue
      exception -> {:error, exception}
    catch
      kind, reason -> {kind, reason}
    end
  end
end
