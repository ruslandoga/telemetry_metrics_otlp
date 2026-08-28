defmodule TelemetryMetricsOTLP.EventHandler do
  @moduledoc false

  alias TelemetryMetricsOTLP.Definition
  alias TelemetryMetricsOTLP.EventPlan.Event

  @type callback_failure :: {:error | :exit | :throw, term()}

  @type error_reason ::
          {:keep, :invalid_return | callback_failure()}
          | {:measurement, :missing | nil | :not_number | callback_failure()}
          | {:tags, :invalid_return | callback_failure()}
          | {:storage, term() | callback_failure()}

  @type handler_id :: {module(), term(), :telemetry.event_name()}

  @spec attach([{Telemetry.event_name(), Event.t()}], term()) ::
          {:ok, [handler_id()]} | {:error, term()}
  def attach(events, instance_id) do
    Enum.reduce_while(events, {:ok, []}, fn {event_name, event}, {:ok, ids} ->
      handler_id = handler_id(instance_id, event_name)

      case :telemetry.attach(handler_id, event_name, &__MODULE__.handle_event/4, event) do
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
          Event.t()
        ) :: :ok
  def handle_event(
        _event_name,
        measurements,
        metadata,
        %Event{metrics: metrics, storage_module: storage_module, storage: storage} = event
      ) do
    # Telemetry invokes handlers synchronously and detaches a handler when an
    # exception escapes. Resolve once for this event, then keep failures local
    # to the individual metric wherever a metric ID is available.
    try do
      resolved = storage_module.resolve(storage)

      Enum.each(metrics, fn metric ->
        record_metric(metric, measurements, metadata, resolved, event)
      end)
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp record_metric(
         {metric, %Definition{id: metric_id} = definition},
         measurements,
         metadata,
         resolved,
         event
       ) do
    case keep?(metric.keep, metadata, measurements) do
      {:ok, true} ->
        record_kept_metric(metric, definition, measurements, metadata, resolved, event)

      {:ok, false} ->
        :ok

      {:error, reason} ->
        record_error(event, resolved, metric_id, {:keep, reason})
    end
  end

  defp record_kept_metric(
         metric,
         %Definition{id: metric_id, kind: :counter} = definition,
         _measurements,
         metadata,
         resolved,
         event
       ) do
    case tags(metric, metadata, event.extract_tags) do
      {:ok, tags} -> insert(event, resolved, definition, 1, tags)
      {:error, reason} -> record_error(event, resolved, metric_id, {:tags, reason})
    end
  end

  defp record_kept_metric(
         metric,
         %Definition{id: metric_id} = definition,
         measurements,
         metadata,
         resolved,
         event
       ) do
    case measurement(metric.measurement, measurements, metadata) do
      {:ok, value} ->
        case tags(metric, metadata, event.extract_tags) do
          {:ok, tags} -> insert(event, resolved, definition, value, tags)
          {:error, reason} -> record_error(event, resolved, metric_id, {:tags, reason})
        end

      {:error, reason} ->
        record_error(event, resolved, metric_id, {:measurement, reason})
    end
  end

  defp keep?(nil, _metadata, _measurements), do: {:ok, true}

  defp keep?(keep, metadata, _measurements) when is_function(keep, 1) do
    try do
      case keep.(metadata) do
        result when is_boolean(result) -> {:ok, result}
        _other -> {:error, :invalid_return}
      end
    rescue
      exception -> {:error, {:error, exception}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp keep?(keep, metadata, measurements) when is_function(keep, 2) do
    try do
      case keep.(metadata, measurements) do
        result when is_boolean(result) -> {:ok, result}
        _other -> {:error, :invalid_return}
      end
    rescue
      exception -> {:error, {:error, exception}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp measurement(measurement, measurements, _metadata) when is_function(measurement, 1) do
    try do
      validate_measurement(measurement.(measurements))
    rescue
      exception -> {:error, {:error, exception}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp measurement(measurement, measurements, metadata) when is_function(measurement, 2) do
    try do
      validate_measurement(measurement.(measurements, metadata))
    rescue
      exception -> {:error, {:error, exception}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp measurement(key, measurements, _metadata) do
    case measurements do
      %{^key => nil} -> {:error, nil}
      %{^key => value} when is_number(value) -> {:ok, value}
      %{^key => _value} -> {:error, :not_number}
      %{} -> {:error, :missing}
      _other -> {:error, :not_number}
    end
  end

  defp validate_measurement(nil), do: {:error, nil}
  defp validate_measurement(value) when is_number(value), do: {:ok, value}
  defp validate_measurement(_value), do: {:error, :not_number}

  defp tags(metric, metadata, extract_tags) when is_function(extract_tags, 2) do
    try do
      validate_tags(extract_tags.(metric, metadata))
    rescue
      exception -> {:error, {:error, exception}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp tags(%{tags: []}, _metadata, nil), do: {:ok, %{}}

  defp tags(%{tags: tags}, metadata, nil) when is_function(tags, 1) do
    try do
      validate_tags(tags.(metadata))
    rescue
      exception -> {:error, {:error, exception}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp tags(%{tags: tags, tag_values: tag_values}, metadata, nil) when is_list(tags) do
    try do
      case validate_tags(tag_values.(metadata)) do
        {:ok, values} -> {:ok, Map.take(values, tags)}
        {:error, reason} -> {:error, reason}
      end
    rescue
      exception -> {:error, {:error, exception}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp validate_tags(tags) when is_map(tags), do: {:ok, tags}
  defp validate_tags(_tags), do: {:error, :invalid_return}

  defp insert(
         %Event{storage_module: storage_module} = event,
         resolved,
         %Definition{id: metric_id} = definition,
         value,
         tags
       ) do
    try do
      result = insert_metric(storage_module, resolved, definition, value, tags)

      case result do
        {:error, reason} -> record_error(event, resolved, metric_id, {:storage, reason})
        _result -> :ok
      end
    rescue
      exception ->
        record_error(event, resolved, metric_id, {:storage, {:error, exception}})
    catch
      kind, reason ->
        record_error(event, resolved, metric_id, {:storage, {kind, reason}})
    end
  end

  defp insert_metric(storage_module, resolved, %Definition{id: id, kind: :counter}, _value, tags) do
    storage_module.insert_counter(resolved, id, tags)
  end

  defp insert_metric(storage_module, resolved, %Definition{id: id, kind: :sum}, value, tags) do
    storage_module.insert_sum(resolved, id, value, tags)
  end

  defp insert_metric(storage_module, resolved, %Definition{id: id, kind: :gauge}, value, tags) do
    storage_module.insert_gauge(resolved, id, value, tags)
  end

  defp insert_metric(
         storage_module,
         resolved,
         %Definition{id: id, kind: :histogram, bounds: bounds},
         value,
         tags
       ) do
    bucket_index = Enum.find_index(bounds, fn bound -> value <= bound end) || length(bounds)
    storage_module.insert_histogram(resolved, id, value, bucket_index, tags)
  end

  defp record_error(
         %Event{storage_module: storage_module},
         resolved,
         metric_id,
         reason
       ) do
    if function_exported?(storage_module, :record_error, 3) do
      try do
        storage_module.record_error(resolved, metric_id, reason)
      rescue
        _exception -> :ok
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end
end
