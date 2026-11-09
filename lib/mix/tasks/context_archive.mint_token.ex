defmodule Mix.Tasks.ContextArchive.MintToken do
  @shortdoc "Mint an API token and write it to a 0600 file (never printed)"
  @moduledoc """
      mix context_archive.mint_token --name laptop-ingest --kind ingest --source laptop --out PATH
      mix context_archive.mint_token --name agents-reader --kind read --scopes agents --out PATH

  The plaintext token is written only to `--out` (created with mode 0600, refusing
  to overwrite). The database stores its SHA-256 hash.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [name: :string, kind: :string, source: :string, scopes: :string, out: :string]
      )

    case ContextArchive.Release.mint_token(opts) do
      {:ok, record} ->
        Mix.shell().info(
          "minted #{record.kind} token #{record.name} (id #{record.id}) -> #{opts[:out]}"
        )

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
