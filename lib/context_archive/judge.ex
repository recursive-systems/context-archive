defmodule ContextArchive.Judge do
  @moduledoc """
  Optional relevance judge. Disabled means no external calls and no cached-judgment
  filtering; historical rows are retained.

  When enabled, asks a judge model, through the configured adapter, whether each
  candidate passage helps answer a question, and keeps a score from 0 to 1 per
  (question, passage) in `Corpus.Judgment`. Adapters implement
  `ContextArchive.Judge.Adapter`:

    * `ContextArchive.Judge.OpenAICompatible` - any `/chat/completions` API
      (OpenAI, OpenRouter, a local Ollama or vLLM, ...)
    * `ContextArchive.Judge.TypeSafe` - TypeSafe Jev through a typesafe-proxy

  Only text of the scopes in `:scopes` (default `agents`) is ever sent, and only masked
  text (what search returns). Configured under `config :context_archive, :judge`:
  `enabled`, `adapter`, `url`, `api_key`, `model`, `scopes`, `concurrency`,
  `timeout_ms`, `budget_ms` (set from the environment in `config/runtime.exs`). Off by
  default and in tests: nothing in the app calls out unless a judge is configured.
  """
  require Ash.Query
  alias ContextArchive.{Corpus.Judgment, Masking}

  # Bump when the question below changes: earlier answers then no longer count.
  @prompt_version 1
  @instructions "Does `passage` help answer `question`? The passage is from an agent's archived work session."
  @criteria %{
    true:
      "It states or directly shows something the question asks for: the fact, decision, reason, event or result asked about.",
    false:
      "It is only on a related topic, shares words with the question, or would need guessing to answer it."
  }

  @doc "What the judge is asked, for adapters."
  def instructions, do: @instructions

  @doc "When the answer is yes (`true`) and when no (`false`), for adapters."
  def criteria, do: @criteria

  defp config, do: Application.get_env(:context_archive, :judge, [])
  def enabled?, do: config()[:enabled] == true
  def adapter, do: config()[:adapter]

  def model do
    config()[:model] || (adapter() && adapter().default_model())
  end

  def scopes, do: config()[:scopes] || ["agents"]

  @doc "The cache key for a question: the question, configured model and prompt version."
  def question_key(question) do
    normalized = question |> String.downcase() |> String.split() |> Enum.join(" ")

    :crypto.hash(:sha256, "#{@prompt_version}\0#{model()}\0#{normalized}")
    |> Base.encode16(case: :lower)
  end

  @doc """
  Judges `candidates` (maps with `chunk_id`, `text`, `kind`, `occurred_at`, `project`,
  `scope`, `document`) against `question`. Returns `{%{chunk_id => noul}, status}`, where
  status is `%{state: "ok" | "partial" | "unavailable" | "disabled", judged:, cached:, error:}`.
  Candidates outside the judged scopes, or whose call failed, have no entry.
  """
  def judge(question, candidates) do
    if enabled?() do
      judge_enabled(question, candidates)
    else
      {%{}, status("disabled", candidates, %{}, %{}, nil)}
    end
  end

  defp judge_enabled(question, candidates) do
    allowed = Enum.filter(candidates, &(&1.scope in scopes()))
    key = question_key(question)
    cached = cached(key, Enum.map(allowed, & &1.chunk_id))
    missing = Enum.reject(allowed, &Map.has_key?(cached, &1.chunk_id))

    cond do
      missing == [] ->
        {cached, status("ok", allowed, cached, %{}, nil)}

      true ->
        {fresh, error} = ask(question, missing)
        store(key, fresh)
        nouls = Map.merge(cached, Map.new(fresh, fn {id, {noul, _model}} -> {id, noul} end))

        state =
          cond do
            map_size(nouls) == length(allowed) -> "ok"
            map_size(nouls) == 0 -> "unavailable"
            true -> "partial"
          end

        {nouls, status(state, allowed, cached, fresh, error)}
    end
  end

  defp status(state, allowed, cached, fresh, error) do
    %{
      state: state,
      model: if(state == "disabled", do: nil, else: model()),
      candidates: length(allowed),
      cached: map_size(cached),
      judged: map_size(fresh),
      error: error
    }
  end

  defp cached(_key, []), do: %{}

  defp cached(key, ids) do
    Judgment
    |> Ash.Query.filter(question_key == ^key and chunk_id in ^ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.chunk_id, &1.noul})
  end

  defp store(_key, fresh) when map_size(fresh) == 0, do: :ok

  defp store(key, fresh) do
    fresh
    |> Enum.map(fn {id, {noul, model}} ->
      %{question_key: key, chunk_id: id, noul: noul, model: model}
    end)
    |> Ash.bulk_create!(Judgment, :record, authorize?: false, return_errors?: true)

    :ok
  end

  # One attempt per candidate, in bounded waves. All waves share one deadline so
  # a slow proxy cannot turn 30 candidates into 75+ seconds and hide the fallback.
  defp ask(question, candidates) do
    timeout = config()[:timeout_ms] || 20_000
    concurrency = config()[:concurrency] || 10
    budget = min(config()[:budget_ms] || 10_000, 10_000)
    deadline = System.monotonic_time(:millisecond) + budget

    results =
      candidates
      |> Enum.chunk_every(concurrency)
      |> Enum.flat_map(fn batch ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          Enum.map(batch, fn _ -> {:error, "judge time budget exceeded"} end)
        else
          batch
          |> Task.async_stream(&ask_one(question, &1, min(timeout, remaining)),
            max_concurrency: concurrency,
            timeout: remaining,
            on_timeout: :kill_task
          )
          |> Enum.zip(batch)
          |> Enum.map(fn
            {{:ok, {:ok, noul, model}}, c} -> {:ok, c.chunk_id, noul, model}
            {{:ok, {:error, why}}, _} -> {:error, why}
            {{:exit, _why}, _} -> {:error, "judge time budget exceeded"}
          end)
        end
      end)

    fresh = for {:ok, id, noul, model} <- results, into: %{}, do: {id, {noul, model}}
    error = Enum.find_value(results, fn r -> match?({:error, _}, r) && elem(r, 1) end)
    {fresh, error}
  end

  defp ask_one(question, c, timeout) do
    request =
      Masking.mask_deep(%{
        question: question,
        passage: %{
          text: String.slice(c.text, 0, 4000),
          kind: c.kind,
          when: c.occurred_at && to_string(c.occurred_at),
          project: c.project,
          session: c.document[:title]
        }
      })

    case adapter() do
      nil -> {:error, "no judge adapter configured"}
      adapter -> adapter.ask(request, Keyword.put(config(), :model, model()), timeout)
    end
  end
end
