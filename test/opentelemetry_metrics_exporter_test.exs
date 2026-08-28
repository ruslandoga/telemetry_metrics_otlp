defmodule OpentelemetryMetricsExporterTest do
  use ExUnit.Case
  doctest OpentelemetryMetricsExporter

  test "greets the world" do
    assert OpentelemetryMetricsExporter.hello() == :world
  end
end
