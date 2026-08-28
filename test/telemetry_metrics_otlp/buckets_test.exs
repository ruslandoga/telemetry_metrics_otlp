defmodule TelemetryMetricsOTLP.BucketsTest do
  use ExUnit.Case, async: true

  alias TelemetryMetricsOTLP.Buckets

  describe "compile!/1 and index/2" do
    test "finds values below, equal to, and between explicit bounds" do
      bounds = Buckets.compile!([1, 5.0, 10])

      assert is_tuple(bounds)
      assert Buckets.index(bounds, -1) == 0
      assert Buckets.index(bounds, 1) == 0
      assert Buckets.index(bounds, 1.0) == 0
      assert Buckets.index(bounds, 2) == 1
      assert Buckets.index(bounds, 5.0) == 1
      assert Buckets.index(bounds, 7.5) == 2
      assert Buckets.index(bounds, 10) == 2
    end

    test "uses the explicit-bound count as the overflow index" do
      bounds = Buckets.compile!([1, 5, 10])

      assert Buckets.index(bounds, 10.1) == tuple_size(bounds)
      assert Buckets.index(bounds, 11) == tuple_size(bounds)
    end

    test "supports an empty explicit-bound list" do
      bounds = Buckets.compile!([])

      assert bounds == {}
      assert Buckets.index(bounds, -100) == 0
      assert Buckets.index(bounds, 100.0) == 0
    end

    test "preserves exact comparisons between large integers and floats" do
      integer_exact_float = 9_007_199_254_740_992
      integer_above_float_precision = integer_exact_float + 1
      bounds = Buckets.compile!([integer_exact_float * 1.0, integer_above_float_precision])

      assert Buckets.index(bounds, integer_exact_float) == 0
      assert Buckets.index(bounds, integer_above_float_precision) == 1
    end
  end

  describe "validation" do
    test "rejects a non-list of bounds" do
      assert_raise ArgumentError, ~r/expected bounds to be a list/, fn ->
        Buckets.compile!({1, 2, 3})
      end
    end

    test "rejects non-numeric bounds" do
      assert_raise ArgumentError, ~r/expected bound at index 1 to be a number/, fn ->
        Buckets.compile!([1, :two, 3])
      end
    end

    test "rejects duplicate and descending bounds" do
      assert_raise ArgumentError, ~r/strictly increasing/, fn ->
        Buckets.compile!([1, 1.0])
      end

      assert_raise ArgumentError, ~r/strictly increasing/, fn ->
        Buckets.compile!([2, 1])
      end
    end

    test "rejects a non-numeric lookup value" do
      bounds = Buckets.compile!([1, 2, 3])

      assert_raise ArgumentError, ~r/expected value to be a number/, fn ->
        Buckets.index(bounds, :not_a_number)
      end
    end
  end
end
