defmodule TelemetryMetricsOTLP.EventPlan do
  @moduledoc """
  Recording plan built from telemetry metric definitions at reporter startup.

  Definitions are keyed by metric name and kind for lookup during collection
  and export. Metrics are also grouped by telemetry event so the reporter can
  attach one handler per event.

  Compatible definitions that share a key remain separate recording
  operations and aggregate into the same storage identity.

  The event configuration deliberately keeps the original metric structs. The
  handler interprets those structs directly, favoring a small and unsurprising
  implementation over a separately compiled hot-path representation.
  """

  alias TelemetryMetricsOTLP.Definition
  alias TelemetryMetricsOTLP.Storage

  defmodule Event do
    @moduledoc false

    alias TelemetryMetricsOTLP.Definition

    @enforce_keys [:metrics, :storage_module, :storage, :extract_tags]
    defstruct [:metrics, :storage_module, :storage, :extract_tags]

    @type t :: %__MODULE__{
            metrics: [{Telemetry.Metrics.t(), Definition.t()}],
            storage_module: module(),
            storage: term(),
            extract_tags: nil | (Telemetry.Metrics.t(), :telemetry.event_metadata() -> map())
          }
  end

  @enforce_keys [:definitions, :events]
  defstruct [:definitions, :events]

  @type event_config :: {:telemetry.event_name(), Event.t()}
  @type t :: %__MODULE__{
          definitions: %{optional(Definition.key()) => Definition.t()},
          events: [event_config()]
        }

  @type option ::
          {:extract_tags, nil | (Telemetry.Metrics.t(), :telemetry.event_metadata() -> map())}

  @spec compile([Telemetry.Metrics.t()], module(), term(), [option()]) ::
          {:ok, t()} | {:error, Exception.t()}
  def compile(metrics, storage_module, storage, options \\ []) do
    {:ok, compile!(metrics, storage_module, storage, options)}
  rescue
    exception -> {:error, exception}
  end

  @spec compile!([Telemetry.Metrics.t()], module(), term(), [option()]) :: t()
  def compile!(metrics, storage_module, storage, options \\ [])

  def compile!(metrics, storage_module, storage, options) when is_list(metrics) do
    Storage.validate!(storage_module)
    extract_tags = extract_tags_option!(options)

    compiled =
      Enum.map(metrics, fn metric ->
        validate_metric!(metric, extract_tags)
        {metric, Definition.compile!(metric)}
      end)

    definitions =
      Enum.reduce(compiled, %{}, fn {_metric, definition}, definitions ->
        put_definition!(definitions, definition)
      end)

    planned =
      Enum.map(compiled, fn {metric, definition} ->
        {metric, Map.fetch!(definitions, definition.key)}
      end)

    {event_groups, event_order} = group_by_event(planned)

    events =
      event_order
      |> Enum.reverse()
      |> Enum.map(fn event_name ->
        event = %Event{
          metrics: event_groups |> Map.fetch!(event_name) |> Enum.reverse(),
          storage_module: storage_module,
          storage: storage,
          extract_tags: extract_tags
        }

        {event_name, event}
      end)

    %__MODULE__{definitions: definitions, events: events}
  end

  def compile!(metrics, _storage_module, _storage, _options) do
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
    case definitions do
      %{^key => existing} ->
        ensure_compatible!(existing, definition)
        Map.put(definitions, key, prefer_description(existing, definition))

      %{} ->
        Map.put(definitions, key, definition)
    end
  end

  defp ensure_compatible!(
         %Definition{unit: unit, bounds: bounds},
         %Definition{unit: unit, bounds: bounds}
       ),
       do: :ok

  defp ensure_compatible!(existing, definition) do
    raise ArgumentError,
          "conflicting metric definitions for #{inspect(definition.key)}: " <>
            "expected matching unit and bounds, got " <>
            "#{inspect(%{unit: existing.unit, bounds: existing.bounds})} and " <>
            inspect(%{unit: definition.unit, bounds: definition.bounds})
  end

  defp prefer_description(existing, definition) do
    preferred =
      case {String.length(existing.description), String.length(definition.description)} do
        {existing_length, definition_length} when existing_length > definition_length ->
          existing.description

        {existing_length, definition_length} when definition_length > existing_length ->
          definition.description

        _equal_lengths ->
          min(existing.description, definition.description)
      end

    %{existing | description: preferred}
  end

  defp group_by_event(indexed) do
    Enum.reduce(indexed, {%{}, []}, fn {metric, _definition} = entry, {groups, order} ->
      event_name = metric.event_name

      case groups do
        %{^event_name => entries} ->
          {Map.put(groups, event_name, [entry | entries]), order}

        %{} ->
          {Map.put(groups, event_name, [entry]), [event_name | order]}
      end
    end)
  end

  defp validate_metric!(metric, extract_tags) do
    validate_keep!(metric.keep)
    validate_tags!(metric, extract_tags)
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

  defp extract_tags_option!(options) when is_list(options) do
    if not Keyword.keyword?(options) do
      raise ArgumentError,
            "expected event plan options to be a keyword list, got: #{inspect(options)}"
    end

    unknown_options = Keyword.keys(options) -- [:extract_tags]

    if unknown_options != [] do
      raise ArgumentError, "unknown event plan options: #{inspect(unknown_options)}"
    end

    case Keyword.get(options, :extract_tags) do
      nil ->
        nil

      function when is_function(function, 2) ->
        function

      other ->
        raise ArgumentError,
              "expected :extract_tags to be a two-arity function or nil, got: #{inspect(other)}"
    end
  end

  defp extract_tags_option!(options) do
    raise ArgumentError,
          "expected event plan options to be a keyword list, got: #{inspect(options)}"
  end
end
