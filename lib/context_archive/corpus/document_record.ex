defmodule ContextArchive.Corpus.DocumentRecord do
  @moduledoc """
  Membership of a record in a document, with provenance: the stream and byte range
  where it was first seen in that document. Ordered by `byte_offset` within a stream.
  """
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Corpus,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "document_records"
    repo ContextArchive.Repo

    references do
      reference :document, on_delete: :restrict
      reference :record, on_delete: :restrict
    end

    custom_indexes do
      index [:record_id]
      index [:document_id, :stream_id, :byte_offset]
    end
  end

  actions do
    defaults [:read]

    create :upsert do
      accept [:id, :document_id, :record_id, :stream_id, :byte_offset, :byte_length, :occurred_at]
      upsert? true
      upsert_identity :unique_membership
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

    attribute :stream_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :byte_offset, :integer do
      allow_nil? false
      public? true
    end

    attribute :byte_length, :integer do
      allow_nil? false
      public? true
    end

    attribute :occurred_at, :utc_datetime_usec, public?: true
  end

  relationships do
    belongs_to :document, ContextArchive.Corpus.Document do
      allow_nil? false
      public? true
    end

    belongs_to :record, ContextArchive.Corpus.Record do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_membership, [:document_id, :record_id]
  end
end
