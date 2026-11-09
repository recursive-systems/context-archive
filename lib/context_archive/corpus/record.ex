defmodule ContextArchive.Corpus.Record do
  @moduledoc """
  One item of a document, stored once per distinct raw content. For Pi: one session
  entry (message, compaction, model change, ...) with its original JSON in `raw`.
  """
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Corpus,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "records"
    repo ContextArchive.Repo

    custom_indexes do
      index [:entry_type, :occurred_at]
      index [:tool_name], where: "tool_name IS NOT NULL"
      index [:occurred_at], where: "is_error", name: "records_errors_index"
    end
  end

  actions do
    defaults [:read]

    create :upsert do
      accept [
        :id,
        :kind,
        :content_sha256,
        :external_id,
        :parent_external_id,
        :entry_type,
        :role,
        :tool_name,
        :is_error,
        :occurred_at,
        :byte_length,
        :raw
      ]

      upsert? true
      upsert_identity :unique_content
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

    attribute :kind, :string do
      allow_nil? false
      public? true
    end

    attribute :content_sha256, :string do
      allow_nil? false
      public? true
    end

    attribute :external_id, :string, public?: true
    attribute :parent_external_id, :string, public?: true
    attribute :entry_type, :string, public?: true
    attribute :role, :string, public?: true
    attribute :tool_name, :string, public?: true

    attribute :is_error, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :occurred_at, :utc_datetime_usec, public?: true
    attribute :byte_length, :integer, public?: true
    attribute :raw, :map, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    has_many :chunks, ContextArchive.Corpus.Chunk
    has_many :document_records, ContextArchive.Corpus.DocumentRecord
  end

  identities do
    identity :unique_content, [:kind, :content_sha256]
  end
end
