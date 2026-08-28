defmodule TelemetryMetricsOTLP.DefinitionTest do
  use ExUnit.Case, async: true

  import Telemetry.Metrics

  alias TelemetryMetricsOTLP.Definition

  describe "compile!/2" do
    test "assigns the id and maps every supported metric kind" do
      metrics = [
        {counter("http.requests.count"), :counter},
        {sum("http.requests.bytes"), :sum},
        {last_value("http.requests.active"), :gauge},
        {distribution("http.requests.duration"), :histogram}
      ]

      for {{metric, expected_kind}, id} <- Enum.with_index(metrics) do
        definition = Definition.compile!(metric, id)

        assert definition.id == id
        assert definition.kind == expected_kind
      end
    end

    test "prejoins the name and normalizes description metadata" do
      metric =
        counter([:my_app, :request, :count],
          description: "Completed requests"
        )

      assert %Definition{
               name: "my_app.request.count",
               description: "Completed requests"
             } = Definition.compile!(metric, 0)

      assert Definition.compile!(sum("my_app.request.bytes"), 1).description == ""
    end

    test "normalizes OTLP units" do
      units = [
        unit: "",
        second: "s",
        millisecond: "ms",
        microsecond: "us",
        nanosecond: "ns",
        byte: "By",
        kilobyte: "kBy",
        megabyte: "MBy",
        gigabyte: "GBy",
        terabyte: "TBy",
        request: "request"
      ]

      for {{unit, expected}, id} <- Enum.with_index(units) do
        metric = last_value("my_app.request.value", unit: unit)

        assert Definition.compile!(metric, id).unit == expected
      end
    end

    test "stores default distribution bounds" do
      definition = Definition.compile!(distribution("http.request.duration"), 0)

      assert definition.bounds == Definition.default_bounds()

      assert definition.bounds == [
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
    end

    test "stores configured distribution bounds without a compiled representation" do
      bounds = [-10, 0, 2.5, 100]

      metric =
        distribution("http.request.duration",
          reporter_options: [buckets: bounds]
        )

      assert Definition.compile!(metric, 0).bounds == bounds
    end

    test "non-distribution metrics have no bounds" do
      metrics = [
        counter("http.request.count", reporter_options: [buckets: [1, 2]]),
        sum("http.request.bytes", reporter_options: [buckets: [1, 2]]),
        last_value("http.request.active", reporter_options: [buckets: [1, 2]])
      ]

      assert Enum.all?(metrics, &(Definition.compile!(&1, 0).bounds == []))
    end

    test "rejects invalid distribution bounds" do
      for bounds <- [[1, 1], [2, 1], [0, :infinity], :not_a_list] do
        metric =
          distribution("http.request.duration",
            reporter_options: [buckets: bounds]
          )

        assert_raise ArgumentError, fn -> Definition.compile!(metric, 0) end
      end
    end

    test "rejects unsupported metric kinds" do
      assert_raise ArgumentError, ~r/unsupported metric definition/, fn ->
        Definition.compile!(summary("http.request.duration"), 0)
      end
    end

    test "rejects ids outside the zero-based integer range" do
      metric = counter("http.request.count")

      for id <- [-1, 1.0, nil] do
        assert_raise ArgumentError, ~r/non-negative integer/, fn ->
          Definition.compile!(metric, id)
        end
      end
    end
  end
end
