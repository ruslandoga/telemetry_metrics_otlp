defmodule TelemetryMetricsOTLP.Handler.Metric do
  @moduledoc false

  require Record

  alias TelemetryMetricsOTLP.Buckets
  alias TelemetryMetricsOTLP.Definition

  Record.defrecord(:handler_metric, [
    :id,
    :type,
    :insert,
    :keep,
    :measurement
  ])

  @type keep :: :no_keep | {:arity_one, function()} | {:arity_two, function()}

  @type measurement ::
          :ignored | {:key, term()} | {:arity_one, function()} | {:arity_two, function()}

  @type t ::
          record(:handler_metric,
            id: non_neg_integer(),
            type: :counter | :measurement,
            insert: (term(), number(), map() -> term()),
            keep: keep(),
            measurement: measurement()
          )

  @spec new(
          Telemetry.Metrics.t(),
          Definition.t(),
          module()
        ) :: t()
  def new(metric, %Definition{} = definition, storage_module) do
    handler_metric(
      id: definition.id,
      type: metric_type(definition.kind),
      insert: compile_insert(definition, storage_module),
      keep: compile_keep(metric.keep),
      measurement: compile_measurement(definition.kind, metric.measurement)
    )
  end

  defp metric_type(:counter), do: :counter
  defp metric_type(_kind), do: :measurement

  defp compile_keep(nil), do: :no_keep
  defp compile_keep(function) when is_function(function, 1), do: {:arity_one, function}
  defp compile_keep(function) when is_function(function, 2), do: {:arity_two, function}

  defp compile_keep(other) do
    raise ArgumentError,
          "expected metric keep to be a one- or two-arity function or nil, got: #{inspect(other)}"
  end

  defp compile_measurement(:counter, _measurement), do: :ignored

  defp compile_measurement(_kind, function) when is_function(function, 1),
    do: {:arity_one, function}

  defp compile_measurement(_kind, function) when is_function(function, 2),
    do: {:arity_two, function}

  defp compile_measurement(_kind, key), do: {:key, key}

  defp compile_insert(%Definition{id: id, kind: :counter}, storage_module) do
    fn resolved, _value, tags -> storage_module.insert_counter(resolved, id, tags) end
  end

  defp compile_insert(%Definition{id: id, kind: :sum}, storage_module) do
    fn resolved, value, tags -> storage_module.insert_sum(resolved, id, value, tags) end
  end

  defp compile_insert(%Definition{id: id, kind: :gauge}, storage_module) do
    fn resolved, value, tags -> storage_module.insert_gauge(resolved, id, value, tags) end
  end

  defp compile_insert(
         %Definition{id: id, kind: :histogram, bounds: bounds},
         storage_module
       ) do
    buckets = Buckets.compile!(bounds)

    fn resolved, value, tags ->
      storage_module.insert_histogram(resolved, id, value, Buckets.index(buckets, value), tags)
    end
  end
end
