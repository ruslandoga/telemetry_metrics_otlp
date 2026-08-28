defmodule TelemetryMetricsOTLP.Storage do
  @moduledoc """
  Contract between the compiled telemetry event plan and metric storage.

  Storage is initialized by the reporter before any telemetry handler is
  attached. `resolve/1` is then called once at the beginning of each event; the
  returned value can select scheduler-local state and is reused by every metric
  produced by that event.

  Every recording callback receives the semantic `{otlp_name, kind}` metric
  key, where `otlp_name` is the prejoined binary name. Tags remain the
  dimensions that identify individual series.

  Recording callbacks receive numeric values without coercion. Histogram
  bucket indexes are zero based and include an overflow bucket at
  `length(definition.bounds)`.

  `record_error/3` is optional. When implemented, it receives observations that
  the event plan skipped, such as missing or non-numeric measurements and
  failures raised by user callbacks. Errors raised by `record_error/3` are
  deliberately ignored so diagnostics cannot detach a telemetry handler.
  """

  alias TelemetryMetricsOTLP.{Definition, EventHandler}

  @type metric_key :: Definition.key()
  @type state :: term()
  @type resolved :: term()
  @type tags :: map()
  @type error_reason :: EventHandler.error_reason()

  @doc "Initializes storage in the reporter process."
  @callback init(options :: term()) :: {:ok, state()} | {:error, term()}

  @doc "Resolves storage for the scheduler executing the current event."
  @callback resolve(state()) :: resolved()

  @callback insert_counter(resolved(), metric_key(), tags()) :: term()
  @callback insert_sum(resolved(), metric_key(), number(), tags()) :: term()
  @callback insert_gauge(resolved(), metric_key(), number(), tags()) :: term()

  @callback insert_histogram(
              resolved(),
              metric_key(),
              number(),
              bucket_index :: non_neg_integer(),
              tags()
            ) :: term()

  @doc "Records a skipped observation without affecting sibling metrics."
  @callback record_error(resolved(), metric_key(), error_reason()) :: term()

  @doc "Releases storage after handlers have been detached."
  @callback terminate(state()) :: term()

  @optional_callbacks record_error: 3, terminate: 1

  @required_callbacks [
    init: 1,
    resolve: 1,
    insert_counter: 3,
    insert_sum: 4,
    insert_gauge: 4,
    insert_histogram: 5
  ]

  @doc false
  @spec validate!(module()) :: :ok
  def validate!(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "could not load storage module #{inspect(module)}: #{inspect(reason)}"
    end

    Enum.each(@required_callbacks, fn {function, arity} ->
      if not function_exported?(module, function, arity) do
        raise ArgumentError,
              "storage module #{inspect(module)} must implement #{function}/#{arity}"
      end
    end)

    :ok
  end

  def validate!(other) do
    raise ArgumentError, "expected a storage module, got: #{inspect(other)}"
  end

  @doc false
  @spec terminate(module(), state()) :: :ok
  def terminate(module, state) do
    if function_exported?(module, :terminate, 1) do
      try do
        module.terminate(state)
      rescue
        _exception -> :ok
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end
end
