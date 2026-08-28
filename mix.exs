defmodule TelemetryMetricsOTLP.MixProject do
  use Mix.Project

  def project do
    [
      app: :telemetry_metrics_otlp,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.4"},
      {:telemetry_metrics, "~> 1.2"},
      {:nimble_options, "~> 1.1"},
      {:protox, "~> 2.0"},
      {:finch, "~> 0.23.0"},
      {:stream_data, "~> 1.4", only: :test},
      {:benchee, "~> 1.5", only: :dev, runtime: false}
    ]
  end
end
