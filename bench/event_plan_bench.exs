defmodule EventPlanBench.NoopStorage do
  @moduledoc false

  @behaviour TelemetryMetricsOTLP.Storage

  @impl true
  def init(_options), do: {:ok, :noop}

  @impl true
  def resolve(:noop), do: :noop

  @impl true
  def insert_counter(:noop, _metric_id, _tags), do: :ok

  @impl true
  def insert_sum(:noop, _metric_id, _value, _tags), do: :ok

  @impl true
  def insert_gauge(:noop, _metric_id, _value, _tags), do: :ok

  @impl true
  def insert_histogram(:noop, _metric_id, _value, _bucket_index, _tags), do: :ok
end

defmodule EventPlanBench.Config do
  @moduledoc false

  def positive_integer(name, default) do
    value = System.get_env(name, Integer.to_string(default))

    case Integer.parse(value) do
      {integer, ""} when integer > 0 ->
        integer

      _other ->
        raise ArgumentError, "expected #{name} to be a positive integer, got: #{inspect(value)}"
    end
  end

  def non_negative_seconds(name, default) do
    value = System.get_env(name, to_string(default))

    case Float.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds

      _other ->
        raise ArgumentError,
              "expected #{name} to be a non-negative number, got: #{inspect(value)}"
    end
  end
end

import Telemetry.Metrics

alias EventPlanBench.Config
alias EventPlanBench.NoopStorage
alias TelemetryMetricsOTLP.EventHandler
alias TelemetryMetricsOTLP.EventPlan

shared_tags = [:route, :status]
shared_tag_values = &Function.identity/1

histogram_bounds = [
  1,
  2,
  4,
  8,
  16,
  32,
  64,
  128,
  256,
  512,
  1_024,
  2_048,
  4_096,
  8_192,
  16_384,
  32_768,
  65_536,
  131_072,
  262_144,
  524_288,
  1_048_576
]

metrics = [
  counter("bench.counter_fast_path.count"),
  counter("bench.mixed_shared_tags.count",
    tags: shared_tags,
    tag_values: shared_tag_values
  ),
  sum("bench.mixed_shared_tags.bytes",
    tags: shared_tags,
    tag_values: shared_tag_values
  ),
  last_value("bench.mixed_shared_tags.inflight",
    tags: shared_tags,
    tag_values: shared_tag_values
  ),
  distribution("bench.mixed_shared_tags.duration",
    tags: shared_tags,
    tag_values: shared_tag_values,
    reporter_options: [buckets: histogram_bounds]
  ),
  sum("bench.function_measurement.scaled_duration",
    measurement: fn measurements, metadata ->
      measurements.duration * metadata.scale
    end
  ),
  distribution("bench.histogram_lookup.duration",
    reporter_options: [buckets: histogram_bounds]
  )
]

plan = EventPlan.compile!(metrics, NoopStorage, :noop)
{:ok, handler_ids} = EventHandler.attach(plan.events, {:event_plan_bench, make_ref()})

counter_event = [:bench, :counter_fast_path]
mixed_event = [:bench, :mixed_shared_tags]
function_event = [:bench, :function_measurement]
histogram_event = [:bench, :histogram_lookup]

mixed_measurements = %{bytes: 512, duration: 1_500, inflight: 42}
shared_metadata = %{route: "/users/:id", status: 200}
function_measurements = %{duration: 750}
function_metadata = %{scale: 1.5}
histogram_measurements = %{duration: 12_345}

parallel = Config.positive_integer("BENCH_PARALLEL", 1)
warmup = Config.non_negative_seconds("BENCH_WARMUP", 2)
time = Config.non_negative_seconds("BENCH_TIME", 5)
memory_time = Config.non_negative_seconds("BENCH_MEMORY_TIME", 2)

IO.puts("""
Compiled #{EventPlan.size(plan)} metrics across #{length(plan.events)} events.
Running with parallel: #{parallel}, warmup: #{warmup}s, time: #{time}s, memory_time: #{memory_time}s
""")

try do
  Benchee.run(
    %{
      "counter fast path" => fn ->
        :telemetry.execute(counter_event, %{}, %{})
      end,
      "mixed shared-tag event" => fn ->
        :telemetry.execute(mixed_event, mixed_measurements, shared_metadata)
      end,
      "function measurement" => fn ->
        :telemetry.execute(function_event, function_measurements, function_metadata)
      end,
      "histogram lookup" => fn ->
        :telemetry.execute(histogram_event, histogram_measurements, %{})
      end
    },
    warmup: warmup,
    time: time,
    memory_time: memory_time,
    parallel: parallel
  )
after
  EventHandler.detach(handler_ids)
end
