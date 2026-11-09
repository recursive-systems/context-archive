defmodule ContextArchive.Access.ApiToken do
  @moduledoc """
  A bearer token. Only its SHA-256 hash is stored; the plaintext is returned once,
  as `token` metadata on the record created by `:mint`.
  """
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Access,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "api_tokens"
    repo ContextArchive.Repo
  end

  actions do
    defaults [:read]

    create :mint do
      accept [:name, :kind, :source_name, :scopes]

      change fn changeset, _context ->
        token = "ca_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        changeset
        |> Ash.Changeset.force_change_attribute(
          :token_hash,
          ContextArchive.Access.hash_token(token)
        )
        |> Ash.Changeset.after_action(fn _changeset, record ->
          {:ok, Ash.Resource.put_metadata(record, :token, token)}
        end)
      end
    end

    update :revoke do
      accept []
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end

    read :active_by_hash do
      argument :token_hash, :string, allow_nil?: false, sensitive?: true
      get? true
      filter expr(token_hash == ^arg(:token_hash) and is_nil(revoked_at))
    end
  end

  validations do
    validate present(:source_name), where: [attribute_equals(:kind, :ingest)]

    validate match(:source_name, ~r/^[a-z][a-z0-9-]{0,62}$/),
      where: [present(:source_name)],
      message: "must be a lowercase machine name"

    validate fn changeset, _context ->
      kind = Ash.Changeset.get_attribute(changeset, :kind)
      scopes = Ash.Changeset.get_attribute(changeset, :scopes) || []
      known = ContextArchive.Access.Scopes.known()

      cond do
        kind == :read and scopes == [] ->
          {:error, field: :scopes, message: "a read token needs at least one scope"}

        Enum.any?(scopes, &(&1 not in known)) ->
          {:error, field: :scopes, message: "unknown scope; known: #{Enum.join(known, ", ")}"}

        true ->
          :ok
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ingest, :read, :admin]
    end

    attribute :source_name, :string do
      public? true
    end

    attribute :scopes, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :token_hash, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :revoked_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :unique_token_hash, [:token_hash]
    identity :unique_name, [:name]
  end
end
