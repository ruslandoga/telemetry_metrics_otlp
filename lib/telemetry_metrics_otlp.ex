defmodule TelemetryMetricsOTLP do
  @moduledoc """
  A correctness-first `Telemetry.Metrics` recording plan for cumulative OTLP
  reporters.

  This package currently provides the recording plan and storage contract. A
  storage implementation is supplied as `{module, options}` and is initialized
  before telemetry handlers are attached:

      TelemetryMetricsOTLP.start_link(
        name: MyReporter,
        metrics: metrics,
        storage: {MyStorage, []}
      )

  See `TelemetryMetricsOTLP.Storage` for the backend callbacks and
  `TelemetryMetricsOTLP.EventPlan` for the compiled metadata API.
  """

  alias TelemetryMetricsOTLP.EventPlan
  alias TelemetryMetricsOTLP.Reporter

  @options_schema NimbleOptions.new!(
                    name: [
                      type: :atom,
                      default: __MODULE__,
                      doc: "Registered reporter name. Use a unique name for each instance."
                    ],
                    metrics: [
                      type: {:list, :any},
                      required: true,
                      doc: "Telemetry.Metrics definitions to compile."
                    ],
                    storage: [
                      type: {:tuple, [:atom, :any]},
                      required: true,
                      doc: "Storage module and its initialization options."
                    ],
                    extract_tags: [
                      type: {:or, [nil, {:fun, 2}]},
                      default: nil,
                      doc:
                        "Optional `(metric, metadata -> tags)` callback replacing the metric's normal tag extraction."
                    ]
                  )

  @type option :: unquote(NimbleOptions.option_typespec(@options_schema))

  @doc "Starts a reporter and attaches its compiled telemetry handlers."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options) do
    with {:ok, validated} <- NimbleOptions.validate(options, @options_schema) do
      Reporter.start_link(Map.new(validated))
    end
  end

  @doc false
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: Keyword.get(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]},
      type: :worker
    }
  end

  @doc "Returns the immutable compiled event plan for a running reporter."
  @spec event_plan(GenServer.server()) :: EventPlan.t()
  def event_plan(reporter), do: GenServer.call(reporter, :plan)
end
