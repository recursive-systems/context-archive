defmodule ContextArchiveWeb.HealthController do
  use ContextArchiveWeb, :controller

  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(ContextArchive.Repo, "SELECT 1", []) do
      {:ok, _} -> json(conn, %{status: "ok"})
      _ -> conn |> put_status(503) |> json(%{status: "database unavailable"})
    end
  end
end
