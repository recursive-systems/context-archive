defmodule ContextArchive.Ids do
  @moduledoc """
  Deterministic UUIDs (version 8, RFC 9562 custom) derived from content.

  Corpus rows get IDs from what they are, not when they were seen: the same Pi entry
  copied into a forked session, or re-parsed after a rebuild, maps to the same row.
  That makes parsing idempotent and lets bulk upserts skip reading IDs back.
  """

  @doc "UUID v8 from a namespace and key parts."
  def uuid(namespace, parts) when is_binary(namespace) and is_list(parts) do
    <<a::48, _::4, b::12, _::2, c::62, _rest::binary>> =
      :crypto.hash(:sha256, Enum.intersperse([namespace | Enum.map(parts, &to_string/1)], <<0>>))

    <<a::48, 8::4, b::12, 2::2, c::62>> |> Ecto.UUID.cast!()
  end
end
