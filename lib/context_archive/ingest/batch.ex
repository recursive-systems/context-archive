defmodule ContextArchive.Ingest.Batch do
  @moduledoc "One accepted byte range of a stream. Append-only: the ingest ledger."
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Ingest,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ingest_batches"
    repo ContextArchive.Repo

    references do
      reference :stream, on_delete: :restrict
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:stream_id, :offset, :length, :sha256]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :offset, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :length, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :sha256, :string do
      allow_nil? false
      public? true
    end

    create_timestamp :received_at
  end

  relationships do
    belongs_to :stream, ContextArchive.Ingest.Stream do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_stream_offset, [:stream_id, :offset]
  end
end
