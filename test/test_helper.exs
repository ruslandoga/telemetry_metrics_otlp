{:ok, _finch} = Finch.start_link(name: :default)

request =
  Finch.build(
    :post,
    "http://localhost:4318/v1/metrics",
    [{"content-type", "application/x-protobuf"}],
    <<>>
  )

case Finch.request(request, :default, receive_timeout: to_timeout(second: 1)) do
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
