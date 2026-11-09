defmodule ContextArchive.Access.Scopes do
  @moduledoc """
  Access scopes. Every source kind maps to one scope; read tokens carry the scopes
  they may see. The mapping lives in config (`:context_archive, :source_kinds`) so
  it can change without code changes; a source's scope can also be changed later
  with `ContextArchive.Ingest.set_source_scope/2`.

    * `agents` - agent sessions; readable by agents with a read token
    * `personal` - the owner's personal sources (e.g. iMessage); owner only
  """

  @known ~w(agents personal)

  def known, do: @known

  @doc "Configured source kinds: %{kind => %{scope: scope, mode: :append | :snapshot}}."
  def source_kinds, do: Application.fetch_env!(:context_archive, :source_kinds)

  @doc "Default scope and mode for a source kind, or :error if the kind is not accepted."
  def fetch_kind(kind) do
    case Map.fetch(source_kinds(), kind) do
      {:ok, spec} -> {:ok, spec}
      :error -> :error
    end
  end
end
