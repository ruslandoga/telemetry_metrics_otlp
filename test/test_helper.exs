{:ok, _finch} = Help.setup()

case Help.http(
       :post,
       "http://localhost:4318/v1/metrics",
       [{"content-type", "application/x-protobuf"}],
       <<>>,
       receive_timeout: to_timeout(second: 1)
     ) do
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
