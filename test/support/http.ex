defmodule ContextArchiveWeb.HTTP do
  @moduledoc """
  Real HTTP requests to the running server (the endpoint's Bandit listener on a free
  loopback port, `config/test.exs`), the way gateways, scripts and the shipper reach the
  archive. Nothing is dispatched in-process.

  `request/3` returns `{status, body, headers}`: the body decoded from JSON when the
  response is JSON (`application/json` or `application/vnd.api+json`), else raw.
  """

  @doc "The server's base URL, e.g. `http://127.0.0.1:41234`."
  def base_url do
    {:ok, {ip, port}} = ContextArchiveWeb.Endpoint.server_info(:http)
    "http://#{:inet.ntoa(ip)}:#{port}"
  end

  @doc """
  Sends a real request. Options: `:token` (bearer), `:json` (a body, sent as
  `application/vnd.api+json` like a gateway's JSON:API calls), `:body` (raw bytes),
  `:params` (query string), `:headers`, `close: true` (a connection of its own, closed
  after the response: for requests the server may answer by dropping the connection).
  """
  def request(method, path, opts \\ []) do
    headers =
      Keyword.get(opts, :headers, []) ++
        if(opts[:close], do: [{"connection", "close"}], else: []) ++
        case opts[:token] do
          nil -> []
          token -> [{"authorization", "Bearer " <> token}]
        end

    req =
      Req.new(
        method: method,
        url: base_url() <> path,
        headers: headers,
        retry: false,
        redirect: false,
        decode_body: false,
        compressed: false,
        receive_timeout: 60_000
      )

    req =
      cond do
        opts[:json] ->
          Req.merge(req,
            body: Jason.encode!(opts[:json]),
            headers: [{"content-type", "application/vnd.api+json"}]
          )

        opts[:body] ->
          Req.merge(req, body: opts[:body])

        true ->
          req
      end

    req = if opts[:params], do: Req.merge(req, params: opts[:params]), else: req

    response = Req.request!(req)
    type = response |> Req.Response.get_header("content-type") |> List.first() || ""

    body =
      if type =~ ~r{^application/(vnd\.api\+)?json} and response.body != "",
        do: Jason.decode!(response.body),
        else: response.body

    {response.status, body, response.headers}
  end
end
