defmodule ContextArchive.Access do
  @moduledoc """
  Who may write to or read from the archive.

  Tokens are bearer secrets shown once at mint time and stored only as SHA-256
  hashes. Three kinds:

    * `:ingest` - may append bytes as exactly one machine (`source_name`)
    * `:read` - may search and read documents whose scope is in `scopes`
    * `:admin` - operator tasks on the VM; never handed to agents
  """
  use Ash.Domain, otp_app: :context_archive

  resources do
    resource ContextArchive.Access.ApiToken do
      define :mint_token, action: :mint
      define :revoke_token, action: :revoke
      define :active_token_by_hash, action: :active_by_hash, args: [:token_hash], get?: true
      define :list_tokens, action: :read
    end
  end

  @doc "SHA-256 hex of a presented bearer token."
  def hash_token(token) when is_binary(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc "Looks up an active (unrevoked) token by its plaintext value."
  def authenticate(token) when is_binary(token) and byte_size(token) > 0 do
    case active_token_by_hash(hash_token(token), authorize?: false) do
      {:ok, api_token} -> {:ok, api_token}
      _ -> :error
    end
  end

  def authenticate(_), do: :error
end
