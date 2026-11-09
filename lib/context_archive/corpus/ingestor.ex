defmodule ContextArchive.Corpus.Ingestor do
  @moduledoc """
  Builds corpus rows from a stream's unparsed bytes, slice by slice, then advances the
  stream's `bytes_parsed`. Every row has a content-derived ID and is upserted, so a
  crash mid-slice just repeats that slice on the next run.

  A stream is parsed when its kind has an adapter (`:source_kinds` in config) and the
  adapter says the path is a session file: Pi (`pi-sessions`), Claude Code
  (`claude-sessions`), Codex (`codex-sessions`), Grok (`grok-sessions`) and the Antigravity CLI
  (`agy-sessions`). Each adapter
  turns its native lines into Pi-shaped entries for the `Chunker`, so every source is
  chunked, embedded and judged the same way. Other kinds and files (`subagent-artifacts/`, `memory/`) are
  archived raw and marked parsed without corpus rows.
  """
  require Logger

  alias ContextArchive.{Corpus, Ids, Ingest}
  alias ContextArchive.Corpus.{Chunk, Chunker, Document, DocumentRecord, Record}
  alias ContextArchive.Ingest.RawStore

  @slice 4 * 1024 * 1024
  @max_line 128 * 1024 * 1024
  @header_probe 1024 * 1024

  @doc "Parses everything received so far. Returns {:ok, bytes_parsed}."
  def ingest(%Ingest.Stream{} = stream) do
    stream = Ash.load!(stream, :source, authorize?: false)

    adapter =
      case ContextArchive.Access.Scopes.fetch_kind(stream.source.kind) do
        {:ok, spec} -> spec[:adapter]
        :error -> nil
      end

    if adapter && adapter.session_path?(stream.path) do
      with {:ok, info} <- read_document_info(stream, adapter),
           {:ok, doc} <- upsert_document(stream, info) do
        loop(stream, adapter, doc, stream.bytes_parsed)
      else
        {:error, :no_header_yet} -> {:ok, stream.bytes_parsed}
        {:error, :not_a_session_header} -> {:ok, stream.bytes_received}
        error -> error
      end
    else
      {:ok, stream.bytes_received}
    end
  end

  # The adapter reads the document's attributes from the first lines (at most
  # @header_probe bytes): Pi and Codex from a header line, Claude Code from the path
  # and the first lines that carry a working directory, Grok from the path and the
  # event ids of the first lines (a fork's parent).
  defp read_document_info(stream, adapter) do
    with {:ok, bytes} <-
           RawStore.read(
             stream.source_id,
             stream.id,
             0,
             min(@header_probe, stream.bytes_received)
           ) do
      lines =
        bytes
        |> :binary.split("\n", [:global])
        |> Enum.drop(-1)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, entry} when is_map(entry) -> [entry]
            _ -> []
          end
        end)

      more? = stream.bytes_received > @header_probe

      case adapter.document_info(lines, stream.path) do
        {:error, :no_header_yet} when more? -> {:error, :not_a_session_header}
        other -> other
      end
    end
  end

  defp upsert_document(stream, info) do
    attrs =
      Map.merge(info, %{
        id: Ids.uuid("document", [info.kind, info.external_id]),
        source_id: stream.source_id,
        scope: stream.source.scope,
        machine: stream.source.machine,
        last_record_at: info.started_at
      })

    Document
    |> Ash.Changeset.for_create(:upsert, attrs, authorize?: false)
    |> Ash.create()
  end

  defp loop(stream, _adapter, _doc, offset) when offset >= stream.bytes_received,
    do: {:ok, offset}

  defp loop(stream, adapter, doc, offset) do
    with {:ok, lines_bytes} <- read_slice(stream, offset),
         :ok <- process_slice(stream, adapter, doc, offset, lines_bytes) do
      new_offset = offset + byte_size(lines_bytes)
      {:ok, _} = Ingest.mark_stream_parsed(stream, new_offset, authorize?: false)
      loop(stream, adapter, doc, new_offset)
    end
  end

  # A slice of whole lines starting at `offset` (streams only ever hold whole lines).
  defp read_slice(stream, offset, size \\ @slice) do
    want = min(size, stream.bytes_received - offset)

    with {:ok, bytes} <- RawStore.read(stream.source_id, stream.id, offset, want) do
      case last_newline(bytes) do
        nil when want < stream.bytes_received - offset and size < @max_line ->
          read_slice(stream, offset, size * 4)

        nil ->
          {:error, {:no_line_boundary, stream.id, offset}}

        n ->
          {:ok, binary_part(bytes, 0, n + 1)}
      end
    end
  end

  defp last_newline(bytes) do
    case :binary.matches(bytes, "\n") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp process_slice(stream, adapter, doc, offset, bytes) do
    {rows, _pos} =
      bytes
      |> :binary.split("\n", [:global])
      |> Enum.drop(-1)
      |> Enum.map_reduce(offset, fn line, pos -> {{line, pos}, pos + byte_size(line) + 1} end)

    parsed =
      rows
      |> Enum.flat_map(fn {line, pos} ->
        case Jason.decode(line) do
          {:ok, entry} when is_map(entry) ->
            if adapter.header?(entry), do: [], else: [{pg_safe(entry), line, pos}]

          _ ->
            Logger.warning("skipping undecodable line at #{stream.id}:#{pos}") && []
        end
      end)

    records =
      Enum.map(parsed, fn {entry, line, _pos} ->
        sha = RawStore.sha256(line)

        entry
        |> adapter.record_info()
        |> Map.merge(%{
          kind: adapter.record_kind(),
          id: Ids.uuid("record", [adapter.record_kind(), sha]),
          content_sha256: sha,
          byte_length: byte_size(line),
          raw: entry
        })
      end)

    memberships =
      Enum.zip_with(parsed, records, fn {_entry, line, pos}, record ->
        %{
          id: Ids.uuid("membership", [doc.id, record.id]),
          document_id: doc.id,
          record_id: record.id,
          stream_id: stream.id,
          byte_offset: pos,
          byte_length: byte_size(line),
          occurred_at: record.occurred_at
        }
      end)

    chunks =
      Enum.zip_with(parsed, records, fn {entry, _line, _pos}, record ->
        for c <- entry |> adapter.to_pi() |> List.wrap() |> Enum.flat_map(&Chunker.chunks/1) do
          %{
            id: Ids.uuid("chunk", [record.id, c.kind, c.part]),
            record_id: record.id,
            document_id: doc.id,
            kind: c.kind,
            part: c.part,
            text: c.text,
            embed?: c.embed?,
            scope: doc.scope,
            machine: doc.machine,
            project: doc.project,
            occurred_at: record.occurred_at,
            metadata: Map.put(c.metadata, "session_id", doc.external_id)
          }
        end
      end)
      |> List.flatten()

    with :ok <- bulk_upsert(Record, records),
         :ok <- bulk_upsert(DocumentRecord, memberships),
         :ok <- bulk_upsert(Chunk, chunks) do
      finish_document(adapter, doc, parsed, records)
    end
  end

  # PostgreSQL text and jsonb cannot hold NUL. Database copies get U+FFFD instead;
  # the raw archive keeps the exact bytes (and the record's content_sha256 is of them).
  @doc false
  def pg_safe(value) when is_binary(value) do
    if String.contains?(value, <<0>>), do: String.replace(value, <<0>>, "\uFFFD"), else: value
  end

  def pg_safe(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {pg_safe(k), pg_safe(v)} end)

  def pg_safe(value) when is_list(value), do: Enum.map(value, &pg_safe/1)
  def pg_safe(value), do: value

  defp bulk_upsert(_resource, []), do: :ok

  defp bulk_upsert(resource, rows) do
    result =
      rows
      |> Enum.uniq_by(& &1.id)
      |> Ash.bulk_create(resource, :upsert,
        authorize?: false,
        batch_size: 500,
        return_errors?: true,
        stop_on_error?: true,
        return_records?: false
      )

    case result do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  defp finish_document(adapter, doc, parsed, records) do
    title =
      parsed
      |> Enum.map(fn {e, _, _} -> adapter.title(e) end)
      |> Enum.reject(&is_nil/1)
      |> List.last()

    latest =
      records
      |> Enum.map(& &1.occurred_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    doc =
      if title && title != doc.title,
        do: Corpus.set_document_title!(doc, title, authorize?: false),
        else: doc

    if latest &&
         (is_nil(doc.last_record_at) or DateTime.compare(latest, doc.last_record_at) == :gt) do
      doc
      |> Ash.Changeset.for_update(:touch, %{last_record_at: latest}, authorize?: false)
      |> Ash.update!()
    end

    :ok
  end
end
