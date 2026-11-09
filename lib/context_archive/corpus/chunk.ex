defmodule ContextArchive.Corpus.Chunk do
  @moduledoc """
  Searchable text derived from one record. Every chunk is full-text indexed
  (`search_vector`, a generated tsvector column); chunks with `embed?` also get
  vectors. `scope`, `machine` and `project` are copied from the document/source so
  search filters do not need joins.
  """
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Corpus,
    data_layer: AshPostgres.DataLayer

  @kinds [
    :user,
    :assistant,
    :thinking,
    :tool_call,
    :tool_output,
    :tool_error,
    :summary,
    :subagent_result,
    :extension_message
  ]

  def kinds, do: @kinds

  postgres do
    table "chunks"
    repo ContextArchive.Repo

    references do
      reference :record, on_delete: :restrict
      reference :document, on_delete: :restrict
    end

    custom_indexes do
      index [:scope, :occurred_at]
      index [:document_id]
      index [:kind]
    end

    custom_statements do
      # Full-text search over every chunk. 'english' gives stemming for prose; exact
      # identifiers (paths, commands, error codes) still match as whole tokens.
      statement :chunks_search_vector do
        up """
        ALTER TABLE chunks ADD COLUMN search_vector tsvector
          GENERATED ALWAYS AS (to_tsvector('english', left(text, 200000))) STORED
        """

        down "ALTER TABLE chunks DROP COLUMN search_vector"
      end

      statement :chunks_search_vector_index do
        up "CREATE INDEX chunks_search_vector_index ON chunks USING GIN (search_vector)"
        down "DROP INDEX chunks_search_vector_index"
      end
    end
  end

  actions do
    defaults [:read]

    create :upsert do
      accept [
        :id,
        :record_id,
        :document_id,
        :kind,
        :part,
        :scope,
        :machine,
        :project,
        :occurred_at,
        :text,
        :embed?,
        :metadata
      ]

      upsert? true
      upsert_identity :unique_part
      upsert_fields []
    end
  end

  attributes do
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      writable? true
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :part, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :scope, :string do
      allow_nil? false
      public? true
    end

    attribute :machine, :string do
      allow_nil? false
      public? true
    end

    attribute :project, :string, public?: true
    attribute :occurred_at, :utc_datetime_usec, public?: true

    attribute :text, :string do
      allow_nil? false
      public? true
      constraints trim?: false, allow_empty?: false
    end

    attribute :embed?, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :record, ContextArchive.Corpus.Record do
      allow_nil? false
      public? true
    end

    belongs_to :document, ContextArchive.Corpus.Document do
      allow_nil? false
      public? true
    end

    has_many :embeddings, ContextArchive.Corpus.Embedding
  end

  identities do
    identity :unique_part, [:record_id, :kind, :part]
  end
end
