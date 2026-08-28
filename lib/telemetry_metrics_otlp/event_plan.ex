defmodule TelemetryMetricsOTLP.EventPlan do
  @moduledoc """
  Recording plan built from telemetry metric definitions at reporter startup.

  Definitions are keyed by metric name and kind for lookup during collection
  and export. Metrics are grouped by telemetry event in their original order.

  Compatible definitions that share a key remain separate recording
  operations and aggregate into the same storage identity.

  The event configuration deliberately keeps the original metric structs. The
  handler interprets those structs directly, favoring a small and unsurprising
  implementation over a separately compiled hot-path representation.
  """

  alias TelemetryMetricsOTLP.Definition

  @enforce_keys [:definitions, :events, :extract_tags]
  defstruct [:definitions, :events, :extract_tags]

  @type extract_tags :: nil | (Telemetry.Metrics.t(), :telemetry.event_metadata() -> map())
  @type event_metrics :: [{Telemetry.Metrics.t(), Definition.t()}]
  @type t :: %__MODULE__{
          definitions: %{optional(Definition.key()) => Definition.t()},
          events: %{optional(:telemetry.event_name()) => event_metrics()},
          extract_tags: extract_tags()
        }

  @spec compile([Telemetry.Metrics.t()], extract_tags()) :: {:ok, t()} | {:error, Exception.t()}
  def compile(metrics, extract_tags \\ nil) do
    {:ok, compile!(metrics, extract_tags)}
  rescue
    exception -> {:error, exception}
  end

  @spec compile!([Telemetry.Metrics.t()], extract_tags()) :: t()
  def compile!(metrics, extract_tags \\ nil)

  def compile!(metrics, extract_tags) when is_list(metrics) do
    validate_extract_tags!(extract_tags)

    compiled =
      Enum.map(metrics, fn metric ->
        validate_metric!(metric, extract_tags)
        {metric, Definition.compile!(metric)}
      end)

    definitions =
      Enum.reduce(compiled, %{}, fn {_metric, definition}, definitions ->
        put_definition!(definitions, definition)
      end)

    events =
      Enum.group_by(
        compiled,
        fn {metric, _definition} -> metric.event_name end,
        fn {metric, definition} -> {metric, Map.fetch!(definitions, definition.key)} end
      )

    %__MODULE__{definitions: definitions, events: events, extract_tags: extract_tags}
  end

  def compile!(metrics, _extract_tags) do
    raise ArgumentError, "expected metrics to be a list, got: #{inspect(metrics)}"
  end

  @doc "Returns the compiled metadata for a metric name and kind."
  @spec fetch_definition(t(), Definition.key()) :: {:ok, Definition.t()} | :error
  def fetch_definition(%__MODULE__{definitions: definitions}, key),
    do: Map.fetch(definitions, key)

  @doc "Returns the number of unique metric storage identities."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{definitions: definitions}), do: map_size(definitions)

  defp put_definition!(definitions, %Definition{key: key} = definition) do
    Map.update(definitions, key, definition, &merge_definition!(&1, definition))
  end

  defp merge_definition!(
         %Definition{unit: unit, bounds: bounds} = existing,
         %Definition{unit: unit, bounds: bounds} = definition
       ) do
    Enum.min_by([existing, definition], &description_rank/1)
  end

  defp merge_definition!(existing, definition) do
    raise ArgumentError,
          "conflicting metric definitions for #{inspect(definition.key)}: " <>
            "expected matching unit and bounds, got " <>
            "#{inspect(%{unit: existing.unit, bounds: existing.bounds})} and " <>
            inspect(%{unit: definition.unit, bounds: definition.bounds})
  end

  defp description_rank(definition),
    do: {-String.length(definition.description), definition.description}

  defp validate_metric!(metric, extract_tags) do
    validate_event_name!(metric.event_name)
    validate_keep!(metric.keep)
    validate_tags!(metric, extract_tags)
  end

  defp validate_event_name!([_segment | _segments] = event_name) when is_list(event_name) do
    if not Enum.all?(event_name, &is_atom/1) do
      raise ArgumentError,
            "expected metric event_name to be a non-empty list of atoms, got: #{inspect(event_name)}"
    end

    :ok
  end

  defp validate_event_name!(event_name) do
    raise ArgumentError,
          "expected metric event_name to be a non-empty list of atoms, got: #{inspect(event_name)}"
  end

  defp validate_keep!(nil), do: :ok
  defp validate_keep!(keep) when is_function(keep, 1) or is_function(keep, 2), do: :ok

  defp validate_keep!(keep) do
    raise ArgumentError,
          "expected metric keep to be a one- or two-arity function or nil, got: #{inspect(keep)}"
  end

  defp validate_tags!(_metric, extract_tags) when is_function(extract_tags, 2), do: :ok

  defp validate_tags!(%{tags: tags}, nil) when is_function(tags, 1), do: :ok

  defp validate_tags!(%{tags: tags, tag_values: tag_values}, nil)
       when is_list(tags) and is_function(tag_values, 1),
       do: :ok

  defp validate_tags!(_metric, nil) do
    raise ArgumentError,
          "expected metric tags to be a list or one-arity function and tag_values to be a one-arity function"
  end

  defp validate_extract_tags!(nil), do: :ok
  defp validate_extract_tags!(extract_tags) when is_function(extract_tags, 2), do: :ok

  defp validate_extract_tags!(extract_tags) do
    raise ArgumentError,
          "expected extract_tags to be a two-arity function or nil, got: #{inspect(extract_tags)}"
  end
end
