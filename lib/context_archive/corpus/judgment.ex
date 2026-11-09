defmodule ContextArchive.Corpus.Judgment do
  @moduledoc """
  A judge's answer to "does this chunk help answer this question?" (`ContextArchive.Judge`),
  kept so the same question costs nothing the second time and `find` can page through its
  results. Derived data, not history: `question_key` covers the question, the judge's
  model alias and its prompt version, so changing either simply asks again.
  """
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Corpus,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "judgments"
    repo ContextArchive.Repo

    references do
      reference :chunk, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:question_key, :chunk_id, :noul, :model]
      upsert? true
      upsert_identity :unique_question_chunk
      upsert_fields [:noul, :model]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :question_key, :string do
      allow_nil? false
      public? true
    end

    attribute :noul, :float do
      allow_nil? false
      public? true
      description "The judge's probability that the chunk helps answer the question."
    end

    attribute :model, :string do
      public? true
      description "The model that answered (the alias resolved, e.g. jev-1.13.0)."
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
    identity :unique_question_chunk, [:question_key, :chunk_id]
  end
end
