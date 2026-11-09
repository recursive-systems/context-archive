defmodule ContextArchive.Corpus.Embedding do
  @moduledoc """
  A vector for one chunk from one embedding model. Keeping the model name on every
  row lets a new model be backfilled side by side before switching searches to it.
  The column is fixed at 384 dimensions (bge-small); a model with other dimensions
  gets its own resource/table rather than a mixed column.
  """
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Corpus,
    data_layer: AshPostgres.DataLayer

  @dimensions 384

  def dimensions, do: @dimensions

  postgres do
    table "embeddings"
    repo ContextArchive.Repo

    references do
      reference :chunk, on_delete: :restrict
    end

    custom_statements do
      statement :embeddings_vector_hnsw do
        up "CREATE INDEX embeddings_vector_hnsw ON embeddings USING hnsw (vector vector_cosine_ops)"
        down "DROP INDEX embeddings_vector_hnsw"
      end
    end
  end

  actions do
    defaults [:read]

    create :upsert do
      accept [:chunk_id, :model, :vector]
      upsert? true
      upsert_identity :unique_chunk_model
      upsert_fields [:vector]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :model, :string do
      allow_nil? false
      public? true
    end

    attribute :vector, :vector do
      allow_nil? false
      public? true
      constraints dimensions: @dimensions
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :chunk, ContextArchive.Corpus.Chunk do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_chunk_model, [:chunk_id, :model]
  end
end
