defmodule ContextArchive.Release do
  @moduledoc """
  Operator tasks for a release, where Mix is not available:

      bin/context_archive eval "ContextArchive.Release.migrate()"
      bin/context_archive rpc 'ContextArchive.Release.mint(name: "laptop-ingest", kind: "ingest", source: "laptop", out: "/data/tokens/laptop.token")'

  `mix context_archive.mint_token` calls `mint_token/1` too, so both write tokens the
  same way: plaintext only to a new 0600 file, never printed; the database keeps a hash.
  """
  @app :context_archive

  @doc "Runs every pending migration (pgvector included)."
  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  `mint_token/1` for the command line (`rpc` into the running release): prints one line
  without the token and returns `:ok`, or raises with the reason.
  """
  def mint(opts) do
    case mint_token(opts) do
      {:ok, record} ->
        IO.puts("minted #{record.kind} token #{record.name} (id #{record.id}) -> #{opts[:out]}")

      {:error, message} ->
        raise ArgumentError, message
    end
  end

  @doc """
  Mints a token and writes it to `out` (created with mode 0600, refusing to overwrite).
  Options: `name`, `kind` (`"ingest"`, `"read"` or `"admin"`), `source` (ingest tokens),
  `scopes` (a list or a comma-separated string; read tokens), `out`.
  Returns `{:ok, record}` or `{:error, message}`. In a release, starts the app first.
  """
  def mint_token(opts) do
    with {:ok, out} <- out_path(opts[:out]),
         {:ok, kind} <- kind(opts[:kind]) do
      ensure_started()

      record =
        ContextArchive.Access.mint_token!(
          %{
            name: opts[:name],
            kind: kind,
            source_name: opts[:source],
            scopes: scopes(opts[:scopes])
          },
          authorize?: false
        )

      File.mkdir_p!(Path.dirname(out))
      {:ok, io} = :file.open(String.to_charlist(out), [:write, :exclusive, :binary])
      :ok = :file.write(io, record.__metadata__.token <> "\n")
      :ok = :file.close(io)
      File.chmod!(out, 0o600)
      {:ok, record}
    end
  end

  defp out_path(nil), do: {:error, "--out is required"}

  defp out_path(out) do
    if File.exists?(out), do: {:error, "#{out} exists; refusing to overwrite"}, else: {:ok, out}
  end

  defp kind(k) when k in ["ingest", "read", "admin"], do: {:ok, String.to_existing_atom(k)}
  defp kind(k) when k in [:ingest, :read, :admin], do: {:ok, k}
  defp kind(_), do: {:error, "--kind must be ingest, read or admin"}

  defp scopes(nil), do: []
  defp scopes(list) when is_list(list), do: list

  defp scopes(string) when is_binary(string),
    do: string |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp load_app, do: Application.load(@app)

  # Under Mix the task's @requirements already started the app; a release eval has not.
  defp ensure_started, do: {:ok, _} = Application.ensure_all_started(@app)
end
