defmodule ContextArchive.Judge.Adapter do
  @moduledoc """
  A judge model behind `ContextArchive.Judge`. One call judges one passage.

  `request` is already masked: `%{question: String.t(), passage: %{text:, kind:, when:,
  project:, session:}}`. `opts` is the `:judge` config (`url`, `api_key`, `model`, ...)
  with `:model` resolved. Return a score from 0.0 (does not help) to 1.0 (answers it) and
  the model that answered, or an error message. Errors are never raised: a failed call
  leaves that passage unjudged.

  Ask with `ContextArchive.Judge.instructions/0` and `ContextArchive.Judge.criteria/0`,
  so every adapter judges the same question.
  """

  @callback ask(request :: map(), opts :: keyword(), timeout :: pos_integer()) ::
              {:ok, float(), String.t() | nil} | {:error, String.t()}

  @doc "The model used when none is configured; nil means one must be configured."
  @callback default_model() :: String.t() | nil

  @doc false
  def url(opts) do
    case opts[:url] do
      url when is_binary(url) and url != "" -> {:ok, String.trim_trailing(url, "/")}
      _ -> {:error, "no judge url configured"}
    end
  end

  @doc false
  def model(opts) do
    case opts[:model] do
      model when is_binary(model) and model != "" -> {:ok, model}
      _ -> {:error, "no judge model configured"}
    end
  end
end
