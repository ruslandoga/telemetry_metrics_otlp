defmodule TelemetryMetricsOTLP.Definition do
  @moduledoc """
  Static OTLP metadata compiled from a `Telemetry.Metrics` definition.

  Compiling this data once keeps metric names, descriptions, units, and
  histogram bounds out of the event handling path.
  """

  alias Telemetry.Metrics.{Counter, Distribution, LastValue, Sum}
  alias TelemetryMetricsOTLP.Buckets

  @default_bounds [
    0,
    5,
    10,
    25,
    50,
    75,
    100,
    250,
    500,
    750,
    1_000,
    2_500,
    5_000,
    7_500,
    10_000
  ]

  @enforce_keys [:id, :kind, :name, :description, :unit, :bounds]
  defstruct [:id, :kind, :name, :description, :unit, :bounds]

  @type kind :: :counter | :sum | :gauge | :histogram

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          kind: kind(),
          name: binary(),
          description: binary(),
          unit: binary(),
          bounds: [number()]
        }

  @doc """
  Returns the explicit histogram bounds used when a distribution does not
  configure `:buckets` in its reporter options.
  """
  @spec default_bounds() :: [number()]
  def default_bounds, do: @default_bounds

  @doc """
  Compiles a supported metric and its zero-based identifier into static OTLP
  metadata.

  Raises `ArgumentError` for an invalid identifier, an unsupported metric
  type, or invalid distribution bounds.
  """
  @spec compile!(Telemetry.Metrics.t(), non_neg_integer()) :: t()
  def compile!(metric, id) do
    validate_id!(id)
    kind = kind!(metric)
    bounds = bounds!(metric)

    %__MODULE__{
      id: id,
      kind: kind,
      name: Enum.map_join(metric.name, ".", &Atom.to_string/1),
      description: normalize_description(metric.description),
      unit: normalize_unit(metric.unit),
      bounds: bounds
    }
  end

  defp validate_id!(id) when is_integer(id) and id >= 0, do: :ok

  defp validate_id!(id) do
    raise ArgumentError, "expected metric id to be a non-negative integer, got: #{inspect(id)}"
  end

  defp kind!(%Counter{}), do: :counter
  defp kind!(%Sum{}), do: :sum
  defp kind!(%LastValue{}), do: :gauge
  defp kind!(%Distribution{}), do: :histogram

  defp kind!(metric) do
    raise ArgumentError, "unsupported metric definition: #{inspect(metric)}"
  end

  defp bounds!(%Distribution{reporter_options: reporter_options}) do
    unless Keyword.keyword?(reporter_options) do
      raise ArgumentError,
            "expected distribution reporter options to be a keyword list, got: #{inspect(reporter_options)}"
    end

    bounds = Keyword.get(reporter_options, :buckets, @default_bounds)

    # Validation and lookup compilation belong to Buckets. Keep only the
    # original list here because it is the metadata required by OTLP encoding.
    _compiled = Buckets.compile!(bounds)

    bounds
  end

  defp bounds!(_metric), do: []

  defp normalize_description(nil), do: ""
  defp normalize_description(description) when is_binary(description), do: description

  defp normalize_description(description) do
    raise ArgumentError,
          "expected metric description to be a string or nil, got: #{inspect(description)}"
  end

  defp normalize_unit(:unit), do: ""
  defp normalize_unit(:second), do: "s"
  defp normalize_unit(:millisecond), do: "ms"
  defp normalize_unit(:microsecond), do: "us"
  defp normalize_unit(:nanosecond), do: "ns"
  defp normalize_unit(:byte), do: "By"
  defp normalize_unit(:kilobyte), do: "kBy"
  defp normalize_unit(:megabyte), do: "MBy"
  defp normalize_unit(:gigabyte), do: "GBy"
  defp normalize_unit(:terabyte), do: "TBy"
  defp normalize_unit(unit) when is_atom(unit), do: Atom.to_string(unit)

  defp normalize_unit(unit) do
    raise ArgumentError, "expected metric unit to be an atom, got: #{inspect(unit)}"
  end
end
