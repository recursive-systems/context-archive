defmodule ContextArchive.Corpus.EmbedWorker do
  @moduledoc """
  Embeds chunks that have `embed?` set and no vector for the current model yet.

  Runs every minute (Oban cron, queue `embed`, concurrency 1) and works for up to
  ~50 s per run, newest chunks first so recent sessions become searchable soonest.
  Within a pick, texts are grouped by length so each batch pads as little as possible.

  The backlog lives in `embed_queue`: a trigger adds every new `embed?` chunk and `store/2`
  removes chunks once their vectors are saved, so neither picking nor counting scans the
  whole archive. Changing `Embeddings.model_name/0` needs a migration that refills the
  queue with the chunks that lack a vector for the new model.
  """
  use Oban.Worker,
    queue: :embed,
    max_attempts: 3,
    unique: [period: 55, states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias ContextArchive.Corpus.Embedding
  alias ContextArchive.{Embeddings, Repo}

  @budget_ms 50_000
  @pick 256

  @impl Oban.Worker
  def perform(_job) do
    if Embeddings.enabled?() do
      deadline = System.monotonic_time(:millisecond) + @budget_ms
      run(deadline, 0)
    else
      :ok
    end
  end

  defp run(deadline, done) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:ok, done}
    else
      case pending(@pick) do
        [] ->
          {:ok, done}

        chunks ->
          chunks
          |> Enum.sort_by(&String.length(&1.text))
          |> Enum.chunk_every(16)
          |> Enum.reduce_while(done, fn batch, acc ->
            store(batch, Embeddings.embed_passages(Enum.map(batch, & &1.text)))

            if System.monotonic_time(:millisecond) >= deadline,
              do: {:halt, acc + length(batch)},
              else: {:cont, acc + length(batch)}
          end)
          |> then(&run(deadline, &1))
      end
    end
  end

  @doc "Chunks still needing a vector for the current model, newest first."
  def pending(limit) do
    from(q in "embed_queue",
      join: c in "chunks",
      on: c.id == q.chunk_id,
      order_by: [desc_nulls_last: q.occurred_at],
      limit: ^limit,
      select: %{id: type(c.id, Ecto.UUID), text: c.text}
    )
    |> Repo.all()
  end

  @doc "Count of chunks still waiting for a vector, optionally only in `scopes` (for /status)."
  def pending_count(scopes \\ nil) do
    query = from(q in "embed_queue", select: count())
    query = if scopes, do: where(query, [q], q.scope in ^scopes), else: query
    Repo.one(query)
  end

  defp store(batch, vectors) do
    model = Embeddings.model_name()

    rows =
      Enum.zip_with(batch, vectors, fn chunk, vector ->
        %{chunk_id: chunk.id, model: model, vector: vector}
      end)

    %Ash.BulkResult{status: :success} =
      Ash.bulk_create(rows, Embedding, :upsert,
        authorize?: false,
        return_errors?: true,
        stop_on_error?: true,
        return_records?: false
      )

    ids = Enum.map(batch, & &1.id)

    Repo.delete_all(
      from(q in "embed_queue", where: q.chunk_id in type(^ids, {:array, Ecto.UUID}))
    )

    :ok
  end
end
