# TelemetryMetricsOTLP

An experimental, correctness-first recording layer for a cumulative
`Telemetry.Metrics` OTLP reporter.

The project is being built in layers. The current implementation normalizes
metric definitions, attaches one handler per telemetry event, and defines the
storage contract that a cumulative scheduler-keyed backend will implement.

## Event plan

At startup, the reporter:

- prejoins metric names and normalizes their static OTLP metadata;
- indexes definitions by the semantic `{name, kind}` storage key;
- rejects definitions that would merge incompatible units or histogram bounds;
- groups metrics by telemetry event;
- completes the static event plan before initializing storage;
- initializes storage before attaching handlers; and
- retains stable reporter-scoped handler IDs for cleanup and restart.

Compatible definitions sharing `{name, kind}` remain separate recording
operations under the same metric identity; matching tags aggregate into the
same series. Plan size and metadata lookup operate on unique identities.

When an event is emitted, its handler resolves storage once and processes each
metric in definition order. The control flow is deliberately direct:

1. evaluate `keep` when configured;
2. obtain and validate the measurement, except for counters;
3. extract the metric's tags;
4. select an inclusive histogram bucket when needed; and
5. call the corresponding storage callback.

Counters increment by one without reading their configured measurement.
Missing, nil, and non-numeric measurements are skipped. Exceptions from user
callbacks or storage operations are isolated to the affected metric so one bad
observation does not detach the event handler. A storage backend can implement
the optional `TelemetryMetricsOTLP.Storage.record_error/3` callback to count
these skips.

Supported definitions are counters, sums, last values (OTLP gauges), and
distributions (OTLP explicit histograms). Summaries are intentionally rejected.

This implementation intentionally favors simple control flow over speculative
hot-path specialization. Compact integer IDs, optimized records, prebound
insert closures, shared tag extraction, and alternative bucket lookup
strategies can be compared against it in a representative benchmark before
being adopted.

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
