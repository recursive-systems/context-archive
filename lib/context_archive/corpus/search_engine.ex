defmodule ContextArchive.Corpus.SearchEngine do
  @moduledoc """
  Retrieval over chunks: keyword (PostgreSQL full text), vector (pgvector cosine,
  HNSW with iterative scans so filters do not starve results), and hybrid
  (reciprocal rank fusion of both, k = 60). No reranking: callers do that.

  After fusion, two generic clean-ups that need no model: near-duplicate passages (the
  same text read in several worktrees, a summary repeated in a report and a notice)
  collapse into the best-ranked one, which counts the others in `duplicates`; and at
  most `per_session` passages come from one session (default 3, none when the caller
  names sessions), so one long session can't fill the results.

  The keyword side ranks every chunk that matches, so a very common word ("tool") costs
  tens of seconds on a million chunks. It gets `@keyword_timeout_ms`; past that, hybrid
  search carries on with the vector side alone and says so in `keyword_timed_out`.
  """
  require Logger
  alias ContextArchive.{Embeddings, Masking, Repo}

  @keyword_timeout_ms 8_000

  @rrf_k 60
  @per_session 3
  # Two passages are near-duplicates when this share of the shorter one's word
  # 3-grams is in the other; passages under @min_shingles 3-grams must match exactly.
  @duplicate_containment 0.8
  @min_shingles 8

  @doc """
  `opts`: `:query` (string), `:mode` (:hybrid | :keyword | :vector), `:limit`,
  `:scopes`, `:filters` (map), `:unmasked?`, `:per_session` (nil = the default),
  `:dedupe` (default true), `:syntax` (:websearch, the default: quotes, `or` and a leading
  `-` are operators; :plain: just words, all of which must match, for natural-language
  questions, where "this or that" would otherwise widen the match to any chunk with "that").
  """
  def search(opts) do
    limit = opts[:limit] || 20
    pool = max(limit * 4, 50)
    filters = normalize_filters(opts[:filters] || %{}, opts[:scopes])
    syntax = opts[:syntax] || :websearch

    {{keyword, keyword_timed_out?}, vector} =
      case opts[:mode] do
        :keyword ->
          {keyword_ranked(opts[:query], filters, pool, syntax), []}

        :vector ->
          {{[], false}, vector_ranked(opts[:query], filters, pool)}

        _ ->
          {keyword_ranked(opts[:query], filters, pool, syntax),
           vector_ranked(opts[:query], filters, pool)}
      end

    fused = fuse(keyword, vector)
    details = details(Enum.map(fused, & &1.id))

    per_session =
      cond do
        is_integer(opts[:per_session]) -> opts[:per_session]
        filters.session_ids -> nil
        true -> @per_session
      end

    results =
      fused
      |> Enum.flat_map(fn r ->
        case Map.fetch(details, r.id) do
          {:ok, d} -> [Map.merge(d, r)]
          :error -> []
        end
      end)
      |> select(limit, per_session, Keyword.get(opts, :dedupe, true))
      |> Enum.map(&present(&1, opts[:unmasked?]))

    {:ok,
     %{
       mode: opts[:mode] || :hybrid,
       embedding_model: Embeddings.model_name(),
       keyword_timed_out: keyword_timed_out?,
       results: results
     }}
  end

  defp normalize_filters(filters, scopes) do
    %{
      scopes: scopes,
      machines: list(filters, "machines"),
      projects: list(filters, "projects"),
      kinds: list(filters, "kinds"),
      session_ids: list(filters, "session_ids"),
      exclude_session_ids: list(filters, "exclude_session_ids"),
      after: time(filters, "after"),
      before: time(filters, "before"),
      errors_only:
        Map.get(filters, "errors_only") == true or Map.get(filters, :errors_only) == true
    }
  end

  defp list(filters, key) do
    case Map.get(filters, key) || Map.get(filters, String.to_atom(key)) do
      [] -> nil
      nil -> nil
      value -> value |> List.wrap() |> Enum.map(&to_string/1)
    end
  end

  defp time(filters, key) do
    case Map.get(filters, key) || Map.get(filters, String.to_atom(key)) do
      %DateTime{} = dt ->
        dt

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Shared filter clause; parameters start at $offset.
  defp filter_sql(f, offset) do
    params = [
      f.scopes,
      f.machines,
      f.projects,
      f.kinds,
      f.session_ids,
      f.after,
      f.before,
      f.errors_only,
      f.exclude_session_ids
    ]

    [s, m, p, k, sid, a, b, e, x] = Enum.map(0..8, &"$#{offset + &1}")

    sql = """
    c.scope = ANY(#{s}::text[])
    AND (#{m}::text[] IS NULL OR c.machine = ANY(#{m}::text[]))
    AND (#{p}::text[] IS NULL OR c.project = ANY(#{p}::text[]))
    AND (#{k}::text[] IS NULL OR c.kind = ANY(#{k}::text[]))
    AND (#{sid}::text[] IS NULL OR c.metadata->>'session_id' = ANY(#{sid}::text[]))
    AND (#{a}::timestamptz IS NULL OR c.occurred_at >= #{a}::timestamptz)
    AND (#{b}::timestamptz IS NULL OR c.occurred_at < #{b}::timestamptz)
    AND (NOT #{e}::boolean OR c.kind = 'tool_error')
    AND (#{x}::text[] IS NULL OR NOT EXISTS (
      SELECT 1 FROM documents xd WHERE xd.id = c.document_id
        AND (xd.external_id = ANY(#{x}::text[]) OR xd.parent_external_id = ANY(#{x}::text[]))))
    """

    {sql, params}
  end

  # {ranked, timed_out?}
  defp keyword_ranked(query, f, pool, syntax) do
    {where, params} = filter_sql(f, 2)
    parse = if syntax == :plain, do: "plainto_tsquery", else: "websearch_to_tsquery"

    sql = """
    SELECT c.id, ts_rank_cd(c.search_vector, q) AS rank
    FROM chunks c, #{parse}('english', $1) q
    WHERE c.search_vector @@ q AND #{where}
    ORDER BY rank DESC
    LIMIT #{pool}
    """

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL statement_timeout = #{@keyword_timeout_ms}")

      case Repo.query(sql, [query | params]) do
        {:ok, %{rows: rows}} -> rows
        {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} -> Repo.rollback(:timeout)
        {:error, error} -> raise error
      end
    end)
    |> case do
      {:ok, rows} ->
        ranked =
          rows
          |> Enum.with_index(1)
          |> Enum.map(fn {[id, rank], i} ->
            %{id: uuid(id), keyword_rank: i, keyword_score: rank}
          end)

        {ranked, false}

      {:error, :timeout} ->
        Logger.warning(
          "keyword search over #{@keyword_timeout_ms} ms (#{String.length(query)}-char query), vector side only"
        )

        {[], true}
    end
  end

  defp vector_ranked(query, f, pool) do
    if Embeddings.enabled?() do
      {:ok, vector} = query |> Embeddings.embed_query() |> Ash.Vector.new()
      {where, params} = filter_sql(f, 3)

      sql = """
      SELECT c.id, 1 - (e.vector <=> $1) AS similarity
      FROM embeddings e JOIN chunks c ON c.id = e.chunk_id
      WHERE e.model = $2 AND #{where}
      ORDER BY e.vector <=> $1
      LIMIT #{pool}
      """

      {:ok, rows} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL hnsw.ef_search = 200")
          Repo.query!("SET LOCAL hnsw.iterative_scan = relaxed_order")
          Repo.query!(sql, [vector, Embeddings.model_name() | params]).rows
        end)

      rows
      |> Enum.sort_by(fn [_id, sim] -> -sim end)
      |> Enum.with_index(1)
      |> Enum.map(fn {[id, sim], i} ->
        %{id: uuid(id), vector_rank: i, vector_similarity: sim}
      end)
    else
      []
    end
  end

  defp fuse(keyword, vector) do
    (keyword ++ vector)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {id, hits} ->
      merged = Enum.reduce(hits, %{id: id}, &Map.merge(&2, &1))
      score = rrf(merged[:keyword_rank]) + rrf(merged[:vector_rank])
      Map.put(merged, :score, score)
    end)
    |> Enum.sort_by(&(-&1.score))
  end

  defp rrf(nil), do: 0.0
  defp rrf(rank), do: 1.0 / (@rrf_k + rank)

  # Best-ranked first, until `limit` are kept. A passage that repeats one already kept is
  # counted on it instead: text that is nearly the same (compared on word 3-grams, so
  # whitespace, case, punctuation, JSON escapes and a prefix such as a notice's header
  # don't hide a repeat), or, within one record, a chunk that is mostly another (a tool
  # call's one-line summary and its arguments; parts of a long text overlap far less).
  # Past `per_session` from one session, a passage is left out.
  defp select(results, limit, per_session, dedupe?) do
    {kept, _, _} =
      Enum.reduce_while(results, {[], [], %{}}, fn r, {kept, seen, counts} ->
        grams = if dedupe?, do: shingles(r.text), else: nil
        dup = dedupe? && Enum.find_index(seen, &duplicate?(&1, {r.record.id, grams}))
        n = Map.get(counts, r.document.id, 0)

        cond do
          is_integer(dup) ->
            at = length(kept) - 1 - dup

            {:cont,
             {List.update_at(kept, at, &Map.update!(&1, :duplicates, fn d -> d + 1 end)), seen,
              counts}}

          per_session && n >= per_session ->
            {:cont, {kept, seen, counts}}

          true ->
            kept = [Map.put(r, :duplicates, 0) | kept]
            acc = {kept, seen ++ [{r.record.id, grams}], Map.put(counts, r.document.id, n + 1)}
            if length(kept) >= limit, do: {:halt, acc}, else: {:cont, acc}
        end
      end)

    Enum.reverse(kept)
  end

  defp shingles(text) do
    words =
      text
      |> String.replace(~r/\\[nrt]/, " ")
      |> String.downcase()
      |> String.split(~r/[^[:alnum:]]+/u, trim: true)

    if length(words) < 3,
      do: MapSet.new([Enum.join(words, " ")]),
      else: words |> Enum.chunk_every(3, 1, :discard) |> MapSet.new(&Enum.join(&1, " "))
  end

  defp duplicate?({record_a, a}, {record_b, b}) do
    small = min(MapSet.size(a), MapSet.size(b))
    contained? = MapSet.size(MapSet.intersection(a, b)) / max(small, 1) >= @duplicate_containment

    cond do
      record_a == record_b -> contained?
      small < @min_shingles -> MapSet.equal?(a, b)
      true -> contained?
    end
  end

  @doc false
  def details([]), do: %{}

  def details(ids) do
    sql = """
    SELECT c.id, c.kind, c.part, c.text, c.occurred_at, c.machine, c.project, c.scope, c.metadata,
           d.id, d.external_id, d.title, d.parent_external_id, d.metadata,
           r.id, r.external_id, r.entry_type, r.role, r.tool_name, r.is_error,
           m.stream_id, m.byte_offset, m.byte_length
    FROM chunks c
    JOIN documents d ON d.id = c.document_id
    JOIN records r ON r.id = c.record_id
    LEFT JOIN document_records m ON m.document_id = c.document_id AND m.record_id = c.record_id
    WHERE c.id = ANY($1::uuid[])
    """

    %{rows: rows} = Repo.query!(sql, [Enum.map(ids, &Ecto.UUID.dump!/1)])

    Map.new(rows, fn [
                       cid,
                       kind,
                       part,
                       text,
                       at,
                       machine,
                       project,
                       scope,
                       cmeta,
                       did,
                       sid,
                       title,
                       parent,
                       dmeta,
                       rid,
                       eid,
                       etype,
                       role,
                       tool,
                       err,
                       stream,
                       off,
                       len
                     ] ->
      {uuid(cid),
       %{
         chunk_id: uuid(cid),
         kind: kind,
         part: part,
         text: text,
         occurred_at: at,
         machine: machine,
         project: project,
         scope: scope,
         tool_name: tool || cmeta["tool_name"],
         document: %{
           id: uuid(did),
           session_id: sid,
           title: title,
           parent_session_id: parent,
           subagent_run_id: dmeta["subagent_run_id"]
         },
         record: %{id: uuid(rid), entry_id: eid, entry_type: etype, role: role, is_error: err},
         source_ref: %{stream_id: stream && uuid(stream), byte_offset: off, byte_length: len}
       }}
    end)
  end

  defp present(result, unmasked?) do
    text = if unmasked?, do: result.text, else: Masking.mask(result.text)

    result
    |> Map.put(:text, text)
    |> Map.take([
      :chunk_id,
      :kind,
      :part,
      :text,
      :score,
      :duplicates,
      :keyword_rank,
      :vector_rank,
      :vector_similarity,
      :occurred_at,
      :machine,
      :project,
      :scope,
      :tool_name,
      :document,
      :record,
      :source_ref
    ])
  end

  defp uuid(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  defp uuid(value) when is_binary(value), do: value
end
