defmodule Help do
  @moduledoc false

  def setup do
    Finch.start_link(name: :default)
  end

  def http(method, url, headers \\ [], body \\ nil, options \\ []) do
    request = Finch.build(method, url, headers, body)
    Finch.request(request, :default, options)
  end
end
