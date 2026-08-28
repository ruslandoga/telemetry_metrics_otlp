defmodule TelemetryMetricsOTLP.Handler.Config do
  @moduledoc false

  require Record

  alias TelemetryMetricsOTLP.Definition
  alias TelemetryMetricsOTLP.Handler.Metric

  Record.defrecord(:handler_config, [
    :groups,
    :storage_module,
    :storage,
    :record_error
  ])

  @type t ::
          record(:handler_config,
            groups: [{:no_tags | (map() -> map()), [Metric.t()]}],
            storage_module: module(),
            storage: term(),
            record_error: (term(), non_neg_integer(), term() -> term())
          )

  @spec new(
          [{Telemetry.Metrics.t(), Definition.t()}],
          module(),
          term(),
          nil | (Telemetry.Metrics.t(), map() -> map())
        ) :: t()
  def new(metrics, storage_module, storage, custom_tag_extractor) do
    {groups, order} =
      Enum.reduce(metrics, {%{}, []}, fn {metric, definition}, acc ->
        compile_metric(metric, definition, storage_module, custom_tag_extractor, acc)
      end)

    handler_config(
      groups: compile_groups(groups, order),
      storage_module: storage_module,
      storage: storage,
      record_error: compile_error_recorder(storage_module)
    )
  end

  defp compile_metric(
         metric,
         definition,
         storage_module,
         custom_tag_extractor,
         {groups, order}
       ) do
    {key, tag_function} = tag_plan(metric, definition.id, custom_tag_extractor)
    operation = Metric.new(metric, definition, storage_module)

    case groups do
      %{^key => {existing_tag_function, metrics}} ->
        {Map.put(groups, key, {existing_tag_function, [operation | metrics]}), order}

      %{} ->
        {Map.put(groups, key, {tag_function, [operation]}), [key | order]}
    end
  end

  # A reporter-level extractor receives the entire definition and may produce
  # different tags for otherwise identical tag settings. Keep those plans
  # metric-local so deduplication never changes its semantics.
  defp tag_plan(metric, metric_id, custom_tag_extractor)
       when is_function(custom_tag_extractor, 2) do
    {{:custom, metric_id}, fn metadata -> custom_tag_extractor.(metric, metadata) end}
  end

  defp tag_plan(%{tags: []}, _metric_id, nil), do: {:no_tags, :no_tags}

  defp tag_plan(%{tags: tags}, _metric_id, nil) when is_function(tags, 1) do
    {{:tags_function, tags}, tags}
  end

  defp tag_plan(%{tag_values: tag_values, tags: tags}, _metric_id, nil) do
    unless is_function(tag_values, 1) and is_list(tags) do
      raise ArgumentError,
            "expected metric tags to be a list and tag_values to be a one-arity function"
    end

    key = {:tag_values, tag_values, tags}
    {key, fn metadata -> metadata |> tag_values.() |> Map.take(tags) end}
  end

  defp compile_groups(groups, order) do
    order
    |> Enum.reverse()
    |> Enum.map(fn key ->
      {tag_function, metrics} = Map.fetch!(groups, key)
      {tag_function, Enum.reverse(metrics)}
    end)
  end

  defp compile_error_recorder(storage_module) do
    if function_exported?(storage_module, :record_error, 3) do
      fn resolved, metric_id, reason ->
        storage_module.record_error(resolved, metric_id, reason)
      end
    else
      fn _resolved, _metric_id, _reason -> :ok end
    end
  end
end
