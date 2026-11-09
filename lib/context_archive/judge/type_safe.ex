defmodule ContextArchive.Judge.TypeSafe do
  @moduledoc """
  TypeSafe Jev through a typesafe-proxy at `url` (the proxy holds the API key; this
  service holds none). One Noul per passage. The model is pinned by default so cached
  answers cannot silently outlive a moving alias.
  """
  @behaviour ContextArchive.Judge.Adapter
  alias ContextArchive.Judge
  alias ContextArchive.Judge.Adapter

  @impl true
  def default_model, do: "jev-1.14.0"

  @impl true
  def ask(%{question: question, passage: passage}, opts, timeout) do
    with {:ok, base} <- Adapter.url(opts),
         {:ok, model} <- Adapter.model(opts) do
      body = %{
        model: model,
        state: %{question: question, passage: passage},
        questions: %{
          answers: %{type: "noul", instructions: Judge.instructions(), criteria: Judge.criteria()}
        }
      }

      case Req.post(base <> "/v1/systemone",
             json: body,
             headers: [{"x-caller", "context-archive find"}],
             receive_timeout: timeout,
             retry: false
           ) do
        {:ok, %{status: 200, body: %{"answers" => %{"answers" => %{"noul" => noul}}} = resp}} ->
          {:ok, noul / 1, resp["model"]}

        {:ok, %{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, e} ->
          {:error, Exception.message(e)}
      end
    end
  end
end
