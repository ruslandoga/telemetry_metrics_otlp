Help.setup()

otlp_url = "http://localhost:4318/v1/metrics"
otlp_headers = [{"content-type", "application/x-protobuf"}]

case Help.http(:post, otlp_url, otlp_headers) do
  {:ok, %Finch.Response{status: 200}} ->
    :ok

  response ->
    Mix.shell().error("""
    OpenTelemetry Collector is not detected at localhost:4318! Please start the local container with the following command:

        docker compose up -d collector

    Collector response: #{inspect(response)}
    """)

    System.halt(1)
end

ExUnit.start()
