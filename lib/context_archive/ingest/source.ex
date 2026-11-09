defmodule ContextArchive.Ingest.Source do
  @moduledoc """
  One kind of data from one machine, e.g. `mini` + `pi-sessions`. Carries the access
  scope every document from it inherits. Only kinds configured in
  `:context_archive, :source_kinds` are accepted, so a new kind (and its scope) is
  always a deliberate configuration change.
  """
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Ingest,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "sources"
    repo ContextArchive.Repo
  end

  actions do
    defaults [:read]

    create :register do
      accept [:machine, :kind]
      upsert? true
      upsert_identity :unique_machine_kind
      # An existing source keeps its (possibly changed) scope.
      upsert_fields []

      change fn changeset, _context ->
        kind = Ash.Changeset.get_attribute(changeset, :kind)

        case ContextArchive.Access.Scopes.fetch_kind(kind) do
          {:ok, %{scope: scope}} ->
            Ash.Changeset.force_change_attribute(changeset, :scope, scope)

          :error ->
            Ash.Changeset.add_error(changeset,
              field: :kind,
              message: "source kind %{kind} is not accepted by this archive",
              vars: [kind: kind]
            )
        end
      end
    end

    update :set_scope do
      accept [:scope]
      # The machine/kind format validations cannot run atomically on unchanged fields.
      require_atomic? false
      validate one_of(:scope, ContextArchive.Access.Scopes.known())
    end
  end

  validations do
    validate match(:machine, ~r/^[a-z][a-z0-9-]{0,62}$/),
      message: "must be a lowercase machine name"

    validate match(:kind, ~r/^[a-z][a-z0-9-]{0,62}$/), message: "must be a lowercase kind name"
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :machine, :string do
      allow_nil? false
      public? true
    end

    attribute :kind, :string do
      allow_nil? false
      public? true
    end

    attribute :scope, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    has_many :streams, ContextArchive.Ingest.Stream
  end

  identities do
    identity :unique_machine_kind, [:machine, :kind]
  end
end
