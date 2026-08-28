# TelemetryMetricsOTLP

An experimental, allocation-conscious event compiler for a cumulative
`Telemetry.Metrics` OTLP reporter.

The project is being built in layers. The current implementation compiles
metric definitions into one handler per telemetry event and defines the storage
contract that the cumulative scheduler-keyed backend will implement.

## Compiled event plan

At startup, the reporter:

- assigns compact zero-based metric IDs;
- stores normalized OTLP metadata in an ID-addressable tuple;
- prejoins metric names and normalizes descriptions and units;
- groups metrics by event and shared tag extraction;
- compiles counter, measurement, `keep`, inclusive histogram bucket, and
  storage insert operations; and
- initializes storage before attaching collision-free handler IDs.

The handler resolves storage once per event. Missing, nil, and non-numeric
measurements are skipped. Exceptions from user callbacks or storage operations
are isolated to the affected metric or shared tag group, preventing one bad
observation from detaching unrelated metrics. A storage backend can implement
the optional `TelemetryMetricsOTLP.Storage.record_error/3` callback to count
these skips.

Because metrics with the same tag plan are executed together, `keep`,
`tag_values`, function-valued `tags`, and `extract_tags` callbacks should be
observationally pure.

Supported metric definitions are counters, sums, last values (OTLP gauges), and
distributions (OTLP explicit histograms). Summaries are intentionally rejected.

## Starting a reporter

A storage implementation is currently required explicitly:

```elixir
TelemetryMetricsOTLP.start_link(
  name: MyReporter,
  metrics: metrics,
  storage: {MyStorage, []}
)
```

Applications that need Logflare-style dynamic tags can replace normal
`tag_values`/`tags` handling with a reporter-level callback:

```elixir
TelemetryMetricsOTLP.start_link(
  name: MyReporter,
  metrics: metrics,
  storage: {MyStorage, []},
  extract_tags: fn metric, metadata ->
    MyApp.Tags.extract(metric, metadata)
  end
)
```

See `TelemetryMetricsOTLP.Storage` for the backend callbacks and
`TelemetryMetricsOTLP.EventPlan` for compiled metadata access.

## Benchmark

Run the event-handler throughput and allocation benchmark in the development
environment:

```sh
MIX_ENV=dev mix run bench/event_plan_bench.exs
```

Set `BENCH_PARALLEL` to compare concurrent event emitters.
