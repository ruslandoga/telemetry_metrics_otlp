defmodule TelemetryMetricsOTLP.Buckets do
  @moduledoc false

  @opaque t :: tuple()

  @doc """
  Validates and compiles explicit histogram upper bounds.

  Bounds must be numbers in strictly increasing numeric order. The original
  integer and float terms are retained so bucket comparisons do not lose
  precision through numeric conversion.
  """
  @spec compile!([number()]) :: t()
  def compile!(bounds) when is_list(bounds) do
    validate_bounds!(bounds)
    List.to_tuple(bounds)
  end

  def compile!(bounds) do
    raise ArgumentError, "expected bounds to be a list, got: #{inspect(bounds)}"
  end

  @doc """
  Returns the zero-based index of the first upper bound containing `value`.

  A value belongs to a bucket when it is less than or equal to that bucket's
  upper bound. Values above every explicit bound use the overflow index, which
  is equal to the number of explicit bounds.
  """
  @spec index(t(), number()) :: non_neg_integer()
  def index(bounds, value) when is_tuple(bounds) and is_number(value) do
    size = tuple_size(bounds)
    find_index(bounds, value, 0, size - 1, size)
  end

  def index(bounds, value) when is_tuple(bounds) do
    raise ArgumentError, "expected value to be a number, got: #{inspect(value)}"
  end

  def index(bounds, _value) do
    raise ArgumentError, "expected compiled bounds to be a tuple, got: #{inspect(bounds)}"
  end

  defp validate_bounds!([]), do: :ok

  defp validate_bounds!([bound | bounds]) when is_number(bound) do
    validate_bounds!(bounds, bound, 1)
  end

  defp validate_bounds!([bound | _bounds]) do
    raise ArgumentError, "expected bound at index 0 to be a number, got: #{inspect(bound)}"
  end

  defp validate_bounds!([], _previous, _index), do: :ok

  defp validate_bounds!([bound | _bounds], _previous, index) when not is_number(bound) do
    raise ArgumentError,
          "expected bound at index #{index} to be a number, got: #{inspect(bound)}"
  end

  defp validate_bounds!([bound | bounds], previous, index) do
    if previous < bound do
      validate_bounds!(bounds, bound, index + 1)
    else
      raise ArgumentError,
            "expected bounds to be strictly increasing, " <>
              "but bound at index #{index} (#{inspect(bound)}) is not greater than " <>
              "#{inspect(previous)}"
    end
  end

  defp find_index(_bounds, _value, low, high, candidate) when low > high, do: candidate

  defp find_index(bounds, value, low, high, candidate) do
    middle = div(low + high, 2)

    if value <= elem(bounds, middle) do
      find_index(bounds, value, low, middle - 1, middle)
    else
      find_index(bounds, value, middle + 1, high, candidate)
    end
  end
end
