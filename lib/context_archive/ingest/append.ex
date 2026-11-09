defmodule ContextArchive.Ingest.Append do
  @moduledoc """
  The `:append` action: verify, lock, write, record. Runs inside one transaction.

  Returns `{:ok, %{status: :ok, generation: g, offset: bytes_received}}`, or
  `{:ok, %{status: :conflict, generation: g, offset: o}}` when the caller's view of
  the stream is stale (the shipper resyncs to the returned position), or an error
  for requests that can never succeed (bad hash, incomplete line, unknown kind).
  """
  use Ash.Resource.Actions.Implementation

  alias ContextArchive.Ingest
  alias ContextArchive.Ingest.{RawStore, Stream}

  @impl true
  def run(input, _opts, _context) do
    args = input.arguments

    with :ok <- verify(args),
         {:ok, source} <- Ingest.register_source(args.machine, args.kind, authorize?: false),
         latest <- lock_latest(source.id, args.path),
         {:ok, stream} <- target_stream(source, latest, args) do
      case stream do
        {:conflict, generation, offset} ->
          {:ok, %{status: :conflict, generation: generation, offset: offset}}

        {:unchanged, s} ->
          {:ok, %{status: :ok, generation: s.generation, offset: s.bytes_received}}

        %Stream{} = s ->
          write(source, s, args)
      end
    end
  end

  # A request that can never succeed is invalid (HTTP 422), not a server error.
  defp verify(%{data: data, sha256: sha, mode: mode}) do
    cond do
      data == "" ->
        invalid(:data, "empty batch")

      RawStore.sha256(data) != String.downcase(sha) ->
        invalid(:sha256, "sha256 mismatch")

      mode == :append and not String.ends_with?(data, "\n") ->
        invalid(:data, "append batches must end at a line boundary")

      true ->
        :ok
    end
  end

  defp invalid(field, message),
    do: {:error, Ash.Error.Action.InvalidArgument.exception(field: field, message: message)}

  defp lock_latest(source_id, path) do
    Stream
    |> Ash.Query.for_read(:latest_for_path, %{source_id: source_id, path: path},
      authorize?: false
    )
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one!()
  end

  # Decide which stream generation this request writes to.
  defp target_stream(source, nil, %{generation: 0, offset: 0} = args), do: open(source, args, 0)

  defp target_stream(_source, nil, _args), do: {:ok, {:conflict, 0, 0}}

  defp target_stream(source, latest, %{mode: :snapshot} = args) do
    cond do
      latest.content_sha256 == String.downcase(args.sha256) ->
        {:ok, {:unchanged, latest}}

      args.generation == latest.generation + 1 and args.offset == 0 ->
        open(source, args, args.generation)

      true ->
        {:ok, {:conflict, latest.generation, latest.bytes_received}}
    end
  end

  defp target_stream(source, latest, args) do
    cond do
      args.generation == latest.generation and args.offset == latest.bytes_received ->
        {:ok, latest}

      args.generation == latest.generation + 1 and args.offset == 0 ->
        open(source, args, args.generation)

      true ->
        {:ok, {:conflict, latest.generation, latest.bytes_received}}
    end
  end

  defp open(source, args, generation) do
    Stream
    |> Ash.Changeset.for_create(
      :open,
      %{source_id: source.id, path: args.path, mode: args.mode, generation: generation},
      authorize?: false
    )
    |> Ash.create()
  end

  defp write(source, stream, args) do
    new_size = args.offset + byte_size(args.data)

    with :ok <- RawStore.write(source.id, stream.id, args.offset, args.data),
         {:ok, head} <- RawStore.head_sha256(source.id, stream.id, new_size),
         {:ok, _batch} <-
           ContextArchive.Ingest.Batch
           |> Ash.Changeset.for_create(
             :record,
             %{
               stream_id: stream.id,
               offset: args.offset,
               length: byte_size(args.data),
               sha256: String.downcase(args.sha256)
             },
             authorize?: false
           )
           |> Ash.create(),
         {:ok, updated} <-
           stream
           |> Ash.Changeset.for_update(
             :record_bytes,
             %{
               bytes_received: new_size,
               head_sha256: head,
               content_sha256:
                 if(args.mode == :snapshot, do: String.downcase(args.sha256), else: nil)
             },
             authorize?: false
           )
           |> Ash.update() do
      {:ok, %{status: :ok, generation: updated.generation, offset: updated.bytes_received}}
    end
  end
end
