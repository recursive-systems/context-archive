defmodule ContextArchive.Ingest.Stream do
  @moduledoc """
  One generation of one file from a source. Append-mode streams grow by complete
  lines; snapshot-mode streams hold exactly one full version of a file that is
  rewritten in place. `bytes_parsed` tracks how far the corpus adapter has read.
  """
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Ingest,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban]

  postgres do
    table "streams"
    repo ContextArchive.Repo

    references do
      reference :source, on_delete: :restrict
    end
  end

  oban do
    triggers do
      # Build corpus rows from newly received bytes. Freshness target: minutes.
      trigger :parse do
        action :parse
        queue :parse_stream
        scheduler_cron "* * * * *"
        where expr(bytes_parsed < bytes_received)
        read_action :pending_parse
        worker_read_action :read
        max_attempts 5
        worker_module_name ContextArchive.Ingest.Stream.AshOban.Worker.Parse
        scheduler_module_name ContextArchive.Ingest.Stream.AshOban.Scheduler.Parse
      end
    end
  end

  actions do
    defaults [:read]

    read :latest_for_path do
      argument :source_id, :uuid, allow_nil?: false
      argument :path, :string, allow_nil?: false
      get? true
      filter expr(source_id == ^arg(:source_id) and path == ^arg(:path))
      prepare build(sort: [generation: :desc], limit: 1)
    end

    read :pending_parse do
      filter expr(bytes_parsed < bytes_received)
      pagination keyset?: true, required?: false
    end

    create :open do
      accept [:source_id, :path, :mode, :generation]
    end

    update :record_bytes do
      accept [:bytes_received, :head_sha256, :content_sha256]
      require_atomic? false
    end

    update :parse do
      description "Run the corpus adapter over unparsed bytes and advance bytes_parsed."
      accept []
      require_atomic? false
      # Slices are upserted and checkpointed one by one; no long wrapping transaction.
      transaction? false

      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          case ContextArchive.Corpus.Ingestor.ingest(changeset.data) do
            {:ok, parsed} ->
              Ash.Changeset.force_change_attribute(changeset, :bytes_parsed, parsed)

            {:error, error} ->
              Ash.Changeset.add_error(changeset, "ingest failed: #{inspect(error, limit: 5)}")
          end
        end)
      end
    end

    update :mark_parsed do
      argument :bytes_parsed, :integer, allow_nil?: false
      require_atomic? false

      change fn changeset, _context ->
        parsed = Ash.Changeset.get_argument(changeset, :bytes_parsed)
        received = changeset.data.bytes_received

        if parsed <= received do
          Ash.Changeset.force_change_attribute(changeset, :bytes_parsed, parsed)
        else
          Ash.Changeset.add_error(changeset,
            field: :bytes_parsed,
            message: "beyond bytes received"
          )
        end
      end
    end

    action :append, :map do
      description "Append a verified byte range to a file's current (or next) generation."
      transaction? true

      argument :machine, :string, allow_nil?: false
      argument :kind, :string, allow_nil?: false
      argument :path, :string, allow_nil?: false
      argument :mode, :atom, allow_nil?: false, constraints: [one_of: [:append, :snapshot]]
      argument :generation, :integer, allow_nil?: false, constraints: [min: 0]
      argument :offset, :integer, allow_nil?: false, constraints: [min: 0]
      argument :sha256, :string, allow_nil?: false
      argument :data, :binary, allow_nil?: false, sensitive?: true

      run ContextArchive.Ingest.Append
    end

    action :state, :map do
      description "Latest generation, offset and hashes per path, for one source."
      argument :machine, :string, allow_nil?: false
      argument :kind, :string, allow_nil?: false

      run fn input, _context ->
        require Ash.Query
        machine = input.arguments.machine
        kind = input.arguments.kind

        streams =
          __MODULE__
          |> Ash.Query.filter(source.machine == ^machine and source.kind == ^kind)
          |> Ash.read!(authorize?: false)

        latest =
          streams
          |> Enum.group_by(& &1.path)
          |> Map.new(fn {path, gens} ->
            s = Enum.max_by(gens, & &1.generation)

            {path,
             %{
               generation: s.generation,
               offset: s.bytes_received,
               head_sha256: s.head_sha256,
               content_sha256: s.content_sha256
             }}
          end)

        {:ok, latest}
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :path, :string do
      allow_nil? false
      public? true
    end

    attribute :mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:append, :snapshot]
    end

    attribute :generation, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :bytes_received, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :bytes_parsed, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :head_sha256, :string do
      public? true
    end

    attribute :content_sha256, :string do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :source, ContextArchive.Ingest.Source do
      allow_nil? false
      public? true
    end

    has_many :batches, ContextArchive.Ingest.Batch
  end

  identities do
    identity :unique_generation, [:source_id, :path, :generation]
  end
end
