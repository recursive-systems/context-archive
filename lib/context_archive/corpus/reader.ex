defmodule ContextArchive.Corpus.Reader do
  @moduledoc """
  Reading documents in order: a range of a session, the context around a hit, and
  archive status. All text is masked unless the caller is an admin asking for raw.
  """
  alias ContextArchive.{Embeddings, Masking, Repo}
  alias ContextArchive.Corpus.EmbedWorker

  @doc "Records of a document (by UUID or session id), in file order, with their text."
  def document(ref, scopes, opts) do
    with {:ok, doc} <- find_document(ref, scopes) do
      after_offset = opts[:after_offset] || -1
      limit = min(opts[:limit] || 50, 200)

      sql = """
      SELECT r.id, r.external_id, r.entry_type, r.role, r.tool_name, r.is_error, r.occurred_at, m.byte_offset,
             coalesce(string_agg(c.kind || ': ' || c.text, E'\\n\\n' ORDER BY c.kind, c.part)
                      FILTER (WHERE c.id IS NOT NULL
                              AND NOT coalesce((c.metadata->>'digest')::boolean, false)), '')
      FROM document_records m
      JOIN records r ON r.id = m.record_id
      LEFT JOIN chunks c ON c.record_id = r.id
      WHERE m.document_id = $1 AND m.byte_offset > $2
      GROUP BY r.id, m.byte_offset
      ORDER BY m.byte_offset
      LIMIT $3
      """

      %{rows: rows} = Repo.query!(sql, [Ecto.UUID.dump!(doc.id), after_offset, limit])

      records =
        Enum.map(rows, fn [rid, eid, type, role, tool, err, at, off, text] ->
          %{
            record_id: Ecto.UUID.load!(rid),
            entry_id: eid,
            entry_type: type,
            role: role,
            tool_name: tool,
            is_error: err,
            occurred_at: at,
            byte_offset: off,
            text: mask(text, opts)
          }
        end)

      {:ok,
       %{
         document: doc,
         records: records,
         next_after_offset:
           if(length(records) == limit, do: List.last(records).byte_offset, else: nil)
       }}
    end
  end

  @doc "The records around a chunk's record in its document."
  def context(chunk_id, scopes, opts) do
    before_n = min(opts[:before] || 5, 50)
    after_n = min(opts[:after] || 5, 50)

    sql = """
    SELECT c.document_id, m.byte_offset
    FROM chunks c JOIN document_records m ON m.document_id = c.document_id AND m.record_id = c.record_id
    WHERE c.id = $1 AND c.scope = ANY($2::text[])
    """

    case Repo.query!(sql, [Ecto.UUID.dump!(chunk_id), scopes]).rows do
      [[doc_id, offset]] ->
        start_sql = """
        SELECT coalesce(min(byte_offset), $2 + 1) - 1 FROM (
          SELECT byte_offset FROM document_records WHERE document_id = $1 AND byte_offset < $2
          ORDER BY byte_offset DESC LIMIT $3) s
        """

        [[start]] = Repo.query!(start_sql, [doc_id, offset, before_n]).rows

        document(
          Ecto.UUID.load!(doc_id),
          scopes,
          Keyword.merge(opts, after_offset: start, limit: before_n + after_n + 1)
        )

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Freshness per source, parse and embedding backlog, corpus size."
  def status(scopes) do
    %{rows: sources} =
      Repo.query!(
        """
        SELECT so.machine, so.kind, so.scope, count(st.id), coalesce(sum(st.bytes_received), 0)::bigint,
               coalesce(sum(st.bytes_received - st.bytes_parsed), 0)::bigint, max(st.updated_at)
        FROM sources so LEFT JOIN streams st ON st.source_id = so.id
        WHERE so.scope = ANY($1::text[])
        GROUP BY so.id ORDER BY so.machine, so.kind
        """,
        [scopes]
      )

    [[documents, chunks, embeddable, embedded]] =
      Repo.query!(
        """
        SELECT (SELECT count(*) FROM documents WHERE scope = ANY($1::text[])),
               (SELECT count(*) FROM chunks WHERE scope = ANY($1::text[])),
               (SELECT count(*) FROM chunks WHERE scope = ANY($1::text[]) AND "embed?"),
               (SELECT count(*) FROM embeddings e JOIN chunks c ON c.id = e.chunk_id
                 WHERE c.scope = ANY($1::text[]) AND e.model = $2)
        """,
        [scopes, Embeddings.model_name()]
      ).rows

    {:ok,
     %{
       sources:
         Enum.map(sources, fn [machine, kind, scope, files, bytes, unparsed, last] ->
           %{
             machine: machine,
             kind: kind,
             scope: scope,
             files: files,
             bytes: bytes,
             unparsed_bytes: unparsed,
             last_received_at: last
           }
         end),
       documents: documents,
       chunks: chunks,
       embedding: %{
         model: Embeddings.model_name(),
         embeddable_chunks: embeddable,
         embedded_chunks: embedded,
         coverage: if(embeddable > 0, do: Float.round(embedded / embeddable, 4), else: 1.0),
         pending_all_scopes: EmbedWorker.pending_count()
       }
     }}
  end

  defp find_document(ref, scopes) do
    # Accept either the document UUID or the source's own id (e.g. the Pi session id).
    sql = """
    SELECT id, kind, external_id, title, machine, project, scope, parent_external_id, metadata, started_at, last_record_at
    FROM documents WHERE (id::text = $1 OR external_id = $1) AND scope = ANY($2::text[])
    LIMIT 1
    """

    case Repo.query!(sql, [ref, scopes]).rows do
      [[id, kind, sid, title, machine, project, scope, parent, meta, started, last]] ->
        {:ok,
         %{
           id: Ecto.UUID.load!(id),
           kind: kind,
           session_id: sid,
           title: title,
           machine: machine,
           project: project,
           scope: scope,
           parent_session_id: parent,
           subagent_run_id: meta["subagent_run_id"],
           started_at: started,
           last_record_at: last
         }}

      [] ->
        {:error, :not_found}
    end
  end

  defp mask(text, opts), do: if(opts[:unmasked?], do: text, else: Masking.mask(text))
end
