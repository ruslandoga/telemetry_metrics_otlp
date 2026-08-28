defmodule TelemetryMetricsOTLP.EventPlan do
  @moduledoc """
  Startup-compiled representation of telemetry metric definitions.

  Definitions receive compact zero-based IDs and are retained in a tuple for
  constant-time lookup during collection/export. Metrics are grouped into one
  handler configuration per telemetry event. Static OTLP fields, user
  callbacks, tag plans, histogram lookup, and storage insert operations are all
  compiled before handlers are attached.

  Recording predicates and tag extractors should be observationally pure.
  Metrics with a shared tag plan are executed together so the extraction result
  can be reused without allocating a per-event cache.
  """

  alias TelemetryMetricsOTLP.Definition
  alias TelemetryMetricsOTLP.Handler.Config
  alias TelemetryMetricsOTLP.Storage

  @enforce_keys [:definitions, :events]
  defstruct [:definitions, :events]

  @type event_config :: {:telemetry.event_name(), Config.t()}
  @type t :: %__MODULE__{definitions: tuple(), events: [event_config()]}

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

    indexed =
      metrics
      |> Enum.with_index()
      |> Enum.map(fn {metric, metric_id} ->
        {metric, Definition.compile!(metric, metric_id)}
      end)

    definitions = indexed |> Enum.map(&elem(&1, 1)) |> List.to_tuple()
    {event_groups, event_order} = group_by_event(indexed)

    events =
      event_order
      |> Enum.reverse()
      |> Enum.map(fn event_name ->
        metrics = event_groups |> Map.fetch!(event_name) |> Enum.reverse()
        {event_name, Config.new(metrics, storage_module, storage, extract_tags)}
      end)

    %__MODULE__{definitions: definitions, events: events}
  end

  def compile!(metrics, _storage_module, _storage, _options) do
    raise ArgumentError, "expected metrics to be a list, got: #{inspect(metrics)}"
  end

  @doc "Returns the compiled metadata for a zero-based metric ID."
  @spec fetch_definition(t(), non_neg_integer()) :: {:ok, Definition.t()} | :error
  def fetch_definition(%__MODULE__{definitions: definitions}, metric_id)
      when is_integer(metric_id) and metric_id >= 0 and metric_id < tuple_size(definitions) do
    {:ok, elem(definitions, metric_id)}
  end

  def fetch_definition(%__MODULE__{}, _metric_id), do: :error

  @doc "Returns the number of compiled metric definitions."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{definitions: definitions}), do: tuple_size(definitions)

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

  defp extract_tags_option!(options) when is_list(options) do
    unless Keyword.keyword?(options) do
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
