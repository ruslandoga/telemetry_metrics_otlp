defmodule TelemetryMetricsOTLP.EventPlanBehaviorTest do
  use ExUnit.Case, async: true

  import Telemetry.Metrics

  alias TelemetryMetricsOTLP.EventHandler
  alias TelemetryMetricsOTLP.EventPlan
  alias TelemetryMetricsOTLP.Test.EventPlanStorage, as: TestStorage

  test "groups metrics by event while preserving compact IDs and static metadata" do
    first_event = unique_event(:first)
    second_event = unique_event(:second)
    state = storage_state()

    metrics = [
      sum("checkout.payload.bytes",
        event_name: first_event,
        measurement: :bytes,
        description: "Payload size",
        unit: :byte
      ),
      counter("checkout.completed.count", event_name: second_event),
      distribution("checkout.duration",
        event_name: first_event,
        measurement: :duration,
        reporter_options: [buckets: [0, 10, 100]]
      )
    ]

    plan = EventPlan.compile!(metrics, TestStorage, state)

    assert EventPlan.size(plan) == 3
    assert Enum.map(plan.events, &elem(&1, 0)) == [first_event, second_event]

    assert {:ok,
            %TelemetryMetricsOTLP.Definition{
              id: 0,
              kind: :sum,
              name: "checkout.payload.bytes",
              description: "Payload size",
              unit: "By",
              bounds: []
            }} = EventPlan.fetch_definition(plan, 0)

    assert {:ok,
            %TelemetryMetricsOTLP.Definition{
              id: 1,
              kind: :counter,
              name: "checkout.completed.count"
            }} = EventPlan.fetch_definition(plan, 1)

    assert {:ok,
            %TelemetryMetricsOTLP.Definition{
              id: 2,
              kind: :histogram,
              bounds: [0, 10, 100]
            }} = EventPlan.fetch_definition(plan, 2)

    assert :error = EventPlan.fetch_definition(plan, 3)

    handler_ids = attach!(plan)
    assert Enum.map(handler_ids, &elem(&1, 2)) == [first_event, second_event]

    :telemetry.execute(first_event, %{bytes: 23, duration: 10}, %{})

    assert storage_events(state) == [
             {:resolve, self()},
             {:insert_sum, 0, 23, %{}},
             {:insert_histogram, 2, 10, 1, %{}}
           ]
  end

  test "resolves storage once and shares list-based tag extraction across metrics" do
    event_name = unique_event(:shared_list_tags)
    state = storage_state()

    tag_values = fn metadata ->
      TestStorage.notify(state, {:callback, :tag_values, metadata})
      metadata
    end

    metrics = [
      sum("shared.left",
        event_name: event_name,
        measurement: :left,
        tags: [:route],
        tag_values: tag_values
      ),
      last_value("shared.right",
        event_name: event_name,
        measurement: :right,
        tags: [:route],
        tag_values: tag_values
      )
    ]

    plan = EventPlan.compile!(metrics, TestStorage, state)
    attach!(plan)

    metadata = %{route: "/orders", ignored: :value}
    :telemetry.execute(event_name, %{left: 7, right: 2.5}, metadata)

    assert storage_events(state) == [
             {:resolve, self()},
             {:callback, :tag_values, metadata},
             {:insert_sum, 0, 7, %{route: "/orders"}},
             {:insert_gauge, 1, 2.5, %{route: "/orders"}}
           ]
  end

  test "shares function-valued tags across metrics" do
    event_name = unique_event(:shared_function_tags)
    state = storage_state()

    tags = fn metadata ->
      TestStorage.notify(state, {:callback, :function_tags, metadata})
      %{tenant: metadata.tenant}
    end

    metrics = [
      counter("function_tags.count", event_name: event_name, tags: tags),
      sum("function_tags.total", event_name: event_name, measurement: :amount, tags: tags)
    ]

    metrics
    |> EventPlan.compile!(TestStorage, state)
    |> attach!()

    metadata = %{tenant: "acme", ignored: true}
    :telemetry.execute(event_name, %{amount: 11}, metadata)

    assert storage_events(state) == [
             {:resolve, self()},
             {:callback, :function_tags, metadata},
             {:insert_counter, 0, %{tenant: "acme"}},
             {:insert_sum, 1, 11, %{tenant: "acme"}}
           ]
  end

  test "custom tag extraction receives each metric definition and metadata" do
    event_name = unique_event(:custom_tags)
    state = storage_state()

    metrics = [
      counter("custom.first", event_name: event_name),
      sum("custom.second", event_name: event_name, measurement: :amount)
    ]

    extract_tags = fn metric, metadata ->
      TestStorage.notify(state, {:callback, :custom_tags, metric.name, metadata})
      %{metric: List.last(metric.name), tenant: metadata.tenant}
    end

    metrics
    |> EventPlan.compile!(TestStorage, state, extract_tags: extract_tags)
    |> attach!()

    metadata = %{tenant: "globex"}
    :telemetry.execute(event_name, %{amount: 19}, metadata)

    assert storage_events(state) == [
             {:resolve, self()},
             {:callback, :custom_tags, [:custom, :first], metadata},
             {:insert_counter, 0, %{metric: :first, tenant: "globex"}},
             {:callback, :custom_tags, [:custom, :second], metadata},
             {:insert_sum, 1, 19, %{metric: :second, tenant: "globex"}}
           ]
  end

  test "invokes keep and measurement callbacks with documented argument order" do
    event_name = unique_event(:keep_order)
    state = storage_state()

    keep_one = fn metadata ->
      TestStorage.notify(state, {:callback, :keep_one, metadata})
      metadata.accept
    end

    measurement_one = fn measurements ->
      TestStorage.notify(state, {:callback, :measurement_one, measurements})
      measurements.left
    end

    keep_two = fn metadata, measurements ->
      TestStorage.notify(state, {:callback, :keep_two, metadata, measurements})
      metadata.accept and measurements.right > 0
    end

    measurement_two = fn measurements, metadata ->
      TestStorage.notify(state, {:callback, :measurement_two, measurements, metadata})
      measurements.right * metadata.multiplier
    end

    reject = fn metadata ->
      TestStorage.notify(state, {:callback, :keep_false, metadata})
      false
    end

    skipped_measurement = fn _measurements ->
      TestStorage.notify(state, {:callback, :unexpected_measurement})
      raise "measurement must not run after keep returns false"
    end

    metrics = [
      sum("keep.one", event_name: event_name, measurement: measurement_one, keep: keep_one),
      last_value("keep.two",
        event_name: event_name,
        measurement: measurement_two,
        keep: keep_two
      ),
      sum("keep.skipped",
        event_name: event_name,
        measurement: skipped_measurement,
        keep: reject
      )
    ]

    metrics
    |> EventPlan.compile!(TestStorage, state)
    |> attach!()

    measurements = %{left: 12, right: 4}
    metadata = %{accept: true, multiplier: 3}
    :telemetry.execute(event_name, measurements, metadata)

    assert storage_events(state) == [
             {:resolve, self()},
             {:callback, :keep_one, metadata},
             {:callback, :measurement_one, measurements},
             {:insert_sum, 0, 12, %{}},
             {:callback, :keep_two, metadata, measurements},
             {:callback, :measurement_two, measurements, metadata},
             {:insert_gauge, 1, 12, %{}},
             {:callback, :keep_false, metadata}
           ]
  end

  test "runs keep and measurement validation before shared tag extraction" do
    event_name = unique_event(:lazy_shared_tags)
    state = storage_state()

    tag_values = fn metadata ->
      TestStorage.notify(state, {:callback, :tag_values, metadata})
      metadata
    end

    metrics = [
      sum("lazy.filtered",
        event_name: event_name,
        measurement: fn _ -> raise "filtered measurement must not run" end,
        keep: fn metadata ->
          TestStorage.notify(state, {:callback, :keep, metadata})
          false
        end,
        tags: [:tenant],
        tag_values: tag_values
      ),
      sum("lazy.missing",
        event_name: event_name,
        measurement: :missing,
        tags: [:tenant],
        tag_values: tag_values
      )
    ]

    metrics
    |> EventPlan.compile!(TestStorage, state)
    |> attach!()

    metadata = %{tenant: "umbrella"}
    :telemetry.execute(event_name, %{}, metadata)

    assert storage_events(state) == [
             {:resolve, self()},
             {:callback, :keep, metadata},
             {:record_error, 1, {:measurement, :missing}}
           ]
  end

  test "supports key, one-arity, and two-arity measurement extraction" do
    event_name = unique_event(:measurement_variants)
    state = storage_state()

    one_arity = fn measurements -> measurements.base / 2 end
    two_arity = fn measurements, metadata -> measurements.base * metadata.factor end

    metrics = [
      sum("measurement.key", event_name: event_name, measurement: :direct),
      last_value("measurement.one", event_name: event_name, measurement: one_arity),
      sum("measurement.two", event_name: event_name, measurement: two_arity)
    ]

    metrics
    |> EventPlan.compile!(TestStorage, state)
    |> attach!()

    :telemetry.execute(event_name, %{direct: -9, base: 7}, %{factor: 4})

    assert storage_events(state) == [
             {:resolve, self()},
             {:insert_sum, 0, -9, %{}},
             {:insert_gauge, 1, 3.5, %{}},
             {:insert_sum, 2, 28, %{}}
           ]
  end

  test "counter paths ignore measurements while still passing measurements to a two-arity keep" do
    event_name = unique_event(:counter_bypass)
    state = storage_state()

    ignored_measurement = fn _measurements, _metadata ->
      TestStorage.notify(state, {:callback, :unexpected_counter_measurement})
      raise "counter measurement must be ignored"
    end

    keep = fn metadata, measurements ->
      TestStorage.notify(state, {:callback, :counter_keep, metadata, measurements})
      metadata.keep
    end

    metrics = [
      counter("counter.fast", event_name: event_name, measurement: ignored_measurement),
      counter("counter.kept",
        event_name: event_name,
        measurement: ignored_measurement,
        keep: keep
      )
    ]

    metrics
    |> EventPlan.compile!(TestStorage, state)
    |> attach!()

    measurements = %{anything: :malformed}
    metadata = %{keep: true}
    :telemetry.execute(event_name, measurements, metadata)

    assert storage_events(state) == [
             {:resolve, self()},
             {:insert_counter, 0, %{}},
             {:callback, :counter_keep, metadata, measurements},
             {:insert_counter, 1, %{}}
           ]
  end

  test "preserves integer and floating-point measurement terms without coercion" do
    event_name = unique_event(:numeric_preservation)
    state = storage_state()

    [sum("numeric.value", event_name: event_name, measurement: :value)]
    |> EventPlan.compile!(TestStorage, state)
    |> attach!()

    values = [-1_208_925_819_614_629_174_706_176, -3.75, 0, 0.0]

    for value <- values do
      :telemetry.execute(event_name, %{value: value}, %{})

      assert [{:resolve, _pid}, {:insert_sum, 0, stored, %{}}] = storage_events(state)
      assert stored === value
    end
  end

  test "records malformed measurements and isolates raised, thrown, and exited callbacks" do
    event_name = unique_event(:measurement_failures)
    state = storage_state()

    metrics = [
      sum("failure.missing", event_name: event_name, measurement: :missing),
      sum("failure.nil", event_name: event_name, measurement: :nil_value),
      last_value("failure.non_numeric", event_name: event_name, measurement: :text),
      sum("failure.raise",
        event_name: event_name,
        measurement: fn _ -> raise "measurement raised" end
      ),
      sum("failure.throw",
        event_name: event_name,
        measurement: fn _ -> throw(:measurement_thrown) end
      ),
      sum("failure.exit",
        event_name: event_name,
        measurement: fn _ -> exit(:measurement_exited) end
      ),
      sum("failure.sibling", event_name: event_name, measurement: :good)
    ]

    plan = EventPlan.compile!(metrics, TestStorage, state)
    [handler_id] = attach!(plan)

    :telemetry.execute(event_name, %{nil_value: nil, text: "bad", good: 41}, %{})

    assert [
             {:resolve, _pid},
             {:record_error, 0, {:measurement, :missing}},
             {:record_error, 1, {:measurement, nil}},
             {:record_error, 2, {:measurement, :not_number}},
             {:record_error, 3,
              {:measurement, {:error, %RuntimeError{message: "measurement raised"}}}},
             {:record_error, 4, {:measurement, {:throw, :measurement_thrown}}},
             {:record_error, 5, {:measurement, {:exit, :measurement_exited}}},
             {:insert_sum, 6, 41, %{}}
           ] = storage_events(state)

    assert handler_id in handler_ids_for(event_name)

    :telemetry.execute(event_name, %{nil_value: nil, text: :bad, good: 42}, %{})
    assert {:insert_sum, 6, 42, %{}} in storage_events(state)
  end

  test "records invalid keep and tag callbacks without suppressing sibling metrics" do
    event_name = unique_event(:keep_and_tag_failures)
    state = storage_state()

    shared_bad_tags = fn metadata ->
      TestStorage.notify(state, {:callback, :shared_bad_tags, metadata})
      raise "tag extraction raised"
    end

    invalid_tags = fn metadata ->
      TestStorage.notify(state, {:callback, :invalid_tags, metadata})
      [:not, :a, :map]
    end

    metrics = [
      sum("callback.invalid_keep",
        event_name: event_name,
        measurement: :value,
        keep: fn _ -> :yes end
      ),
      sum("callback.raised_keep",
        event_name: event_name,
        measurement: :value,
        keep: fn _, _ -> raise "keep raised" end
      ),
      sum("callback.bad_tags_one",
        event_name: event_name,
        measurement: :value,
        tags: shared_bad_tags
      ),
      counter("callback.bad_tags_two", event_name: event_name, tags: shared_bad_tags),
      sum("callback.invalid_tags",
        event_name: event_name,
        measurement: :value,
        tags: invalid_tags
      ),
      sum("callback.good_sibling", event_name: event_name, measurement: :value)
    ]

    metrics
    |> EventPlan.compile!(TestStorage, state)
    |> attach!()

    metadata = %{tenant: "initech"}
    :telemetry.execute(event_name, %{value: 5}, metadata)

    assert [
             {:resolve, _pid},
             {:record_error, 0, {:keep, :invalid_return}},
             {:record_error, 1, {:keep, {:error, %RuntimeError{message: "keep raised"}}}},
             {:insert_sum, 5, 5, %{}},
             {:callback, :shared_bad_tags, ^metadata},
             {:record_error, 2,
              {:tags, {:error, %RuntimeError{message: "tag extraction raised"}}}},
             {:record_error, 3,
              {:tags, {:error, %RuntimeError{message: "tag extraction raised"}}}},
             {:callback, :invalid_tags, ^metadata},
             {:record_error, 4, {:tags, :invalid_return}}
           ] = storage_events(state)
  end

  test "isolates storage failures and failures in the optional error recorder" do
    event_name = unique_event(:storage_failures)

    state =
      storage_state(%{
        failures: %{
          {:sum, 0} => {:return, {:error, :busy}},
          {:gauge, 1} => {:raise, "gauge insert raised"},
          {:counter, 2} => {:throw, :counter_insert_thrown},
          :record_error => {:raise, "diagnostics unavailable"}
        }
      })

    metrics = [
      sum("storage.sum", event_name: event_name, measurement: :value),
      last_value("storage.gauge", event_name: event_name, measurement: :value),
      counter("storage.counter", event_name: event_name),
      sum("storage.sibling", event_name: event_name, measurement: :value)
    ]

    plan = EventPlan.compile!(metrics, TestStorage, state)
    [handler_id] = attach!(plan)

    :telemetry.execute(event_name, %{value: 8}, %{})

    assert [
             {:resolve, _pid},
             {:insert_sum, 0, 8, %{}},
             {:record_error, 0, {:storage, :busy}},
             {:insert_gauge, 1, 8, %{}},
             {:record_error, 1,
              {:storage, {:error, %RuntimeError{message: "gauge insert raised"}}}},
             {:insert_counter, 2, %{}},
             {:record_error, 2, {:storage, {:throw, :counter_insert_thrown}}},
             {:insert_sum, 3, 8, %{}}
           ] = storage_events(state)

    assert handler_id in handler_ids_for(event_name)
  end

  test "uses inclusive explicit histogram bounds and an overflow bucket" do
    event_name = unique_event(:histogram_boundaries)
    state = storage_state()

    [
      distribution("histogram.value",
        event_name: event_name,
        measurement: :value,
        reporter_options: [buckets: [-1, 0, 2.5]]
      )
    ]
    |> EventPlan.compile!(TestStorage, state)
    |> attach!()

    observations = [{-2, 0}, {-1, 0}, {0, 1}, {2.5, 2}, {2.500_001, 3}]

    for {value, expected_bucket} <- observations do
      :telemetry.execute(event_name, %{value: value}, %{})

      assert [
               {:resolve, _pid},
               {:insert_histogram, 0, stored, ^expected_bucket, %{}}
             ] = storage_events(state)

      assert stored === value
    end
  end

  test "supports multiple reporter instances, detaches on stop, and restarts cleanly" do
    event_name = unique_event(:reporter_lifecycle)
    name_one = unique_name(:reporter_one)
    name_two = unique_name(:reporter_two)
    metric = counter("reporter.lifecycle.count", event_name: event_name)
    state_one = storage_state(%{observe_event: event_name})
    state_two = storage_state(%{observe_event: event_name})

    {:ok, reporter_one} =
      TelemetryMetricsOTLP.start_link(
        name: name_one,
        metrics: [metric],
        storage: {TestStorage, state_one}
      )

    stop_on_exit(reporter_one)
    assert [{:init, ^reporter_one, 0}] = storage_events(state_one)

    {:ok, reporter_two} =
      TelemetryMetricsOTLP.start_link(
        name: name_two,
        metrics: [metric],
        storage: {TestStorage, state_two}
      )

    stop_on_exit(reporter_two)
    assert [{:init, ^reporter_two, 1}] = storage_events(state_two)

    [handler_one] = TelemetryMetricsOTLP.handler_ids(reporter_one)
    [handler_two] = TelemetryMetricsOTLP.handler_ids(reporter_two)
    refute handler_one == handler_two
    assert MapSet.new(handler_ids_for(event_name)) == MapSet.new([handler_one, handler_two])

    :telemetry.execute(event_name, %{}, %{})

    assert storage_events(state_one) == [
             {:resolve, self()},
             {:insert_counter, 0, %{}}
           ]

    assert storage_events(state_two) == [
             {:resolve, self()},
             {:insert_counter, 0, %{}}
           ]

    :ok = GenServer.stop(reporter_one)
    assert [{:terminate, ^reporter_one}] = storage_events(state_one)
    assert handler_ids_for(event_name) == [handler_two]

    :telemetry.execute(event_name, %{}, %{})
    assert storage_events(state_one) == []

    assert storage_events(state_two) == [
             {:resolve, self()},
             {:insert_counter, 0, %{}}
           ]

    :ok = GenServer.stop(reporter_two)
    assert [{:terminate, ^reporter_two}] = storage_events(state_two)
    assert handler_ids_for(event_name) == []

    restarted_state = storage_state(%{observe_event: event_name})

    {:ok, restarted} =
      TelemetryMetricsOTLP.start_link(
        name: name_one,
        metrics: [metric],
        storage: {TestStorage, restarted_state}
      )

    stop_on_exit(restarted)
    assert [{:init, ^restarted, 0}] = storage_events(restarted_state)
    [restarted_handler] = TelemetryMetricsOTLP.handler_ids(restarted)
    assert restarted_handler == handler_one

    :telemetry.execute(event_name, %{}, %{})

    assert storage_events(restarted_state) == [
             {:resolve, self()},
             {:insert_counter, 0, %{}}
           ]

    :ok = GenServer.stop(restarted)
    assert [{:terminate, ^restarted}] = storage_events(restarted_state)
    assert handler_ids_for(event_name) == []
  end

  test "restart after an untrappable kill removes stale handlers for deleted events" do
    removed_event = unique_event(:removed_after_kill)
    retained_event = unique_event(:retained_after_kill)
    name = unique_name(:killed_reporter)
    old_state = storage_state(%{observe_event: retained_event})

    old_metrics = [
      counter("restart.removed.count", event_name: removed_event),
      counter("restart.retained.count", event_name: retained_event)
    ]

    {:ok, old_reporter} =
      TelemetryMetricsOTLP.start_link(
        name: name,
        metrics: old_metrics,
        storage: {TestStorage, old_state}
      )

    stop_on_exit(old_reporter)
    assert [{:init, ^old_reporter, 0}] = storage_events(old_state)

    old_handlers = TelemetryMetricsOTLP.handler_ids(old_reporter)
    old_removed_handler = EventHandler.handler_id(name, removed_event)
    old_retained_handler = EventHandler.handler_id(name, retained_event)
    assert MapSet.new(old_handlers) == MapSet.new([old_removed_handler, old_retained_handler])

    Process.unlink(old_reporter)
    monitor = Process.monitor(old_reporter)
    Process.exit(old_reporter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_reporter, :killed}

    assert Enum.sort(handler_ids_for(removed_event) ++ handler_ids_for(retained_event)) ==
             Enum.sort(old_handlers)

    assert storage_events(old_state) == []

    restarted_state = storage_state(%{observe_event: retained_event})
    retained_metric = counter("restart.retained.count", event_name: retained_event)

    {:ok, restarted} =
      TelemetryMetricsOTLP.start_link(
        name: name,
        metrics: [retained_metric],
        storage: {TestStorage, restarted_state}
      )

    stop_on_exit(restarted)
    assert [{:init, ^restarted, 0}] = storage_events(restarted_state)
    assert handler_ids_for(removed_event) == []
    assert handler_ids_for(retained_event) == [old_retained_handler]

    :telemetry.execute(removed_event, %{}, %{})
    assert storage_events(old_state) == []
    assert storage_events(restarted_state) == []

    :telemetry.execute(retained_event, %{}, %{})
    assert storage_events(old_state) == []

    assert storage_events(restarted_state) == [
             {:resolve, self()},
             {:insert_counter, 0, %{}}
           ]

    :ok = GenServer.stop(restarted)
    assert [{:terminate, ^restarted}] = storage_events(restarted_state)
    assert handler_ids_for(retained_event) == []
  end

  test "initializes and terminates storage when event-plan compilation fails" do
    event_name = unique_event(:reporter_compile_failure)
    name = unique_name(:invalid_reporter)
    state = storage_state(%{observe_event: event_name})
    metric = summary("unsupported.summary", event_name: event_name)

    Process.flag(:trap_exit, true)

    assert {:error, {:event_plan_failed, %ArgumentError{} = exception}} =
             TelemetryMetricsOTLP.start_link(
               name: name,
               metrics: [metric],
               storage: {TestStorage, state}
             )

    assert Exception.message(exception) =~ "unsupported metric definition"

    assert [{:init, reporter_pid, 0}, {:terminate, terminated_pid}] = storage_events(state)
    assert terminated_pid == reporter_pid

    assert handler_ids_for(event_name) == []
  end

  test "terminates initialized storage for non-ArgumentError plan failures" do
    event_name = unique_event(:malformed_definition)
    name = unique_name(:malformed_reporter)
    state = storage_state(%{observe_event: event_name})
    metric = %{counter("malformed.metric", event_name: event_name) | name: nil}

    Process.flag(:trap_exit, true)

    assert {:error, {:event_plan_failed, %Protocol.UndefinedError{}}} =
             TelemetryMetricsOTLP.start_link(
               name: name,
               metrics: [metric],
               storage: {TestStorage, state}
             )

    assert [{:init, reporter_pid, 0}, {:terminate, terminated_pid}] = storage_events(state)
    assert terminated_pid == reporter_pid
    assert handler_ids_for(event_name) == []
  end

  test "rolls back earlier attachments when a later handler ID collides" do
    first_event = unique_event(:rollback_first)
    second_event = unique_event(:rollback_second)
    state = storage_state()

    metrics = [
      counter("rollback.first", event_name: first_event),
      counter("rollback.second", event_name: second_event)
    ]

    plan = EventPlan.compile!(metrics, TestStorage, state)
    instance_id = make_ref()
    first_handler = EventHandler.handler_id(instance_id, first_event)
    colliding_handler = EventHandler.handler_id(instance_id, second_event)

    :ok =
      :telemetry.attach(
        colliding_handler,
        second_event,
        &TestStorage.handle_event/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(colliding_handler) end)

    assert {:error, {:attach_failed, ^second_event, :already_exists}} =
             EventHandler.attach(plan.events, instance_id)

    refute first_handler in handler_ids_for(first_event)
    assert colliding_handler in handler_ids_for(second_event)
  end

  defp storage_state(extra \\ %{}) do
    Map.merge(%{owner: self(), token: make_ref(), failures: %{}}, Map.new(extra))
  end

  defp storage_events(%{token: token}), do: storage_events(token, [])

  defp storage_events(token, events) do
    receive do
      {TestStorage, ^token, event} -> storage_events(token, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp attach!(%EventPlan{} = plan) do
    {:ok, handler_ids} = EventHandler.attach(plan.events, make_ref())
    on_exit(fn -> EventHandler.detach(handler_ids) end)
    handler_ids
  end

  defp handler_ids_for(event_name) do
    event_name
    |> :telemetry.list_handlers()
    |> Enum.map(& &1.id)
  end

  defp stop_on_exit(pid) do
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)
  end

  defp unique_event(label), do: [__MODULE__, unique_name(label)]

  defp unique_name(label) do
    String.to_atom("#{label}_#{System.unique_integer([:positive, :monotonic])}")
  end
end
