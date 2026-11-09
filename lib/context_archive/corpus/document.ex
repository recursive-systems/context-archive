defmodule ContextArchive.Corpus.Document do
  @moduledoc """
  A conversation or thread. For Pi: one session (subagent children are their own
  documents pointing at their parent through `parent_external_id`).
  """
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Corpus,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "documents"
    repo ContextArchive.Repo

    references do
      reference :source, on_delete: :restrict
    end

    custom_indexes do
      index [:parent_external_id]
      index [:scope, :machine, :last_record_at]
    end
  end

  actions do
    defaults [:read]

    create :upsert do
      accept [
        :id,
        :source_id,
        :kind,
        :external_id,
        :scope,
        :machine,
        :project,
        :parent_external_id,
        :metadata,
        :started_at,
        :last_record_at
      ]

      upsert? true
      upsert_identity :unique_kind_external_id
      upsert_fields [:project, :parent_external_id, :metadata, :started_at, :last_record_at]
    end

    update :set_title do
      accept [:title]
    end

    update :touch do
      accept [:last_record_at]
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

    attribute :external_id, :string do
      allow_nil? false
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

    attribute :title, :string, public?: true
    attribute :project, :string, public?: true
    attribute :parent_external_id, :string, public?: true

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :started_at, :utc_datetime_usec, public?: true
    attribute :last_record_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :source, ContextArchive.Ingest.Source do
      domain ContextArchive.Ingest
      allow_nil? false
      public? true
    end

    has_many :document_records, ContextArchive.Corpus.DocumentRecord
  end

  identities do
    identity :unique_kind_external_id, [:kind, :external_id]
  end
end
