defmodule ContextArchiveWeb.Plugs.ApiTokenAuth do
  @moduledoc """
  Authenticates `Authorization: Bearer <token>` and assigns the token as the actor.
  `kinds:` restricts which token kinds may use the pipeline.
  """
  import Plug.Conn

  def init(opts), do: Keyword.fetch!(opts, :kinds)

  def call(conn, kinds) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, api_token} <- ContextArchive.Access.authenticate(String.trim(token)),
         true <- api_token.kind in kinds do
      conn
      |> assign(:api_token, api_token)
      |> Ash.PlugHelpers.set_actor(api_token)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"unauthorized"}))
        |> halt()
    end
  end
end
