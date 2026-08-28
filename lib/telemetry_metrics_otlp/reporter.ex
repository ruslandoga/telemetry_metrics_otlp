defmodule TelemetryMetricsOTLP.Reporter do
  @moduledoc false

  use GenServer

  alias TelemetryMetricsOTLP.EventHandler
  alias TelemetryMetricsOTLP.EventPlan
  alias TelemetryMetricsOTLP.Storage

  defmodule State do
    @moduledoc false

    @enforce_keys [
      :instance_id,
      :plan,
      :handler_ids,
      :storage_module,
      :storage
    ]
    defstruct @enforce_keys
  end

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(options) when is_map(options) do
    GenServer.start_link(__MODULE__, options, name: options.name)
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    {storage_module, storage_options} = options.storage

    # A process killed with `:kill` cannot run terminate/2. The registered name
    # has already been acquired, so stable reporter-scoped IDs can be cleaned
    # here without clobbering another live instance. Scan first even when the
    # new configuration later proves invalid, and include removed events.
    EventHandler.detach_namespace(options.name)

    case validate_storage(storage_module) do
      :ok ->
        case init_storage(storage_module, storage_options) do
          {:ok, storage} ->
            start_plan(options, storage_module, storage)

          {:error, reason} ->
            {:stop, {:storage_init_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:invalid_storage, reason}}
    end
  end

  @impl true
  def handle_call(:plan, _from, %State{plan: plan} = state) do
    {:reply, plan, state}
  end

  @impl true
  def handle_call(:handler_ids, _from, %State{handler_ids: handler_ids} = state) do
    {:reply, handler_ids, state}
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    EventHandler.detach(state.handler_ids)
    Storage.terminate(state.storage_module, state.storage)
  end

  defp start_plan(options, storage_module, storage) do
    plan_options = [extract_tags: options.extract_tags]

    case EventPlan.compile(options.metrics, storage_module, storage, plan_options) do
      {:ok, plan} ->
        instance_id = options.name

        case EventHandler.attach(plan.events, instance_id) do
          {:ok, handler_ids} ->
            state = %State{
              instance_id: instance_id,
              plan: plan,
              handler_ids: handler_ids,
              storage_module: storage_module,
              storage: storage
            }

            {:ok, state}

          {:error, reason} ->
            Storage.terminate(storage_module, storage)
            {:stop, reason}
        end

      {:error, reason} ->
        Storage.terminate(storage_module, storage)
        {:stop, {:event_plan_failed, reason}}
    end
  end

  defp init_storage(storage_module, storage_options) do
    try do
      case storage_module.init(storage_options) do
        {:ok, storage} -> {:ok, storage}
        {:error, _reason} = error -> error
        other -> {:error, {:invalid_return, other}}
      end
    rescue
      exception -> {:error, {:error, exception}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp validate_storage(storage_module) do
    try do
      Storage.validate!(storage_module)
    rescue
      exception -> {:error, exception}
    end
  end
end
