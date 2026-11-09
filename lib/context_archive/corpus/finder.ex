defmodule ContextArchive.Corpus.Finder do
  @moduledoc """
  `find`: fused candidate excerpts across several phrasings, judged for relevance.
  When judging is disabled, `unjudged` is paginated in search order and the agent
  evaluates relevance. Failed or excluded judgments also remain explicitly unjudged.

  1. One hybrid search per phrasing (the question and up to four more the caller gives),
     with the caller's filters; each already collapses near-duplicates and caps one session.
  2. Fuses those lists by reciprocal rank (a passage several phrasings find ranks higher)
     and keeps the best `candidates`.
  3. Asks the judge (`ContextArchive.Judge`) of each whether it helps answer the question;
     answers are cached, so repeats and further pages cost nothing.
  4. Returns, best first, the passages judged at or above `threshold`, a page at a time,
     each cut to `excerpt_chars` around the question's words, never the whole chunk.

  The answer is bounded: at most `limit` results, `limit` unjudged ones (only when some
  candidates couldn't be judged: the judge is off or failing, or their scope is never sent
  out) and 3 nearest misses (only when nothing passed). With nothing passing, `results` is
  empty: the caller is told so instead of getting passages that merely look related.
  """
  require Logger
  alias ContextArchive.{Judge, Corpus.SearchEngine}

  @per_query 20
  @nearest 3
  @stop ~w(about after also been before could does from have into just more that their them
           then there these they this were what when where which while with would your will
           should only some than very)

  def find(opts) do
    question = opts[:question]

    queries =
      [question | List.wrap(opts[:queries])]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    limit = opts[:limit] || 6
    offset = opts[:offset] || 0
    threshold = opts[:threshold] || 0.5

    # Phrasings are plain words: a question's "or" is not an operator. One phrasing that
    # fails or runs out of time is left out rather than failing the whole find.
    searches =
      queries
      |> Task.async_stream(
        fn q ->
          {:ok, %{results: r, keyword_timed_out: slow?}} =
            SearchEngine.search(
              query: q,
              mode: opts[:mode] || :hybrid,
              syntax: :plain,
              limit: @per_query,
              scopes: opts[:scopes],
              filters: opts[:filters] || %{},
              unmasked?: false
            )

          {r, slow?}
        end,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, found} ->
          found

        {:exit, reason} ->
          Logger.warning("find: a phrasing's search failed: #{inspect(reason, limit: 5)}")
          {[], true}
      end)

    lists = Enum.map(searches, &elem(&1, 0))
    shortlist = fuse(lists) |> Enum.take(opts[:candidates] || 30)
    {nouls, judge} = Judge.judge(question, shortlist)
    scored = Enum.map(shortlist, &Map.put(&1, :score, Map.get(nouls, &1.chunk_id)))

    judged =
      scored
      |> Enum.filter(& &1.score)
      |> Enum.sort_by(&{-&1.score, -&1.fused})

    hits = Enum.filter(judged, &(&1.score >= threshold))
    terms = terms(queries)
    show = &present(&1, terms, opts[:excerpt_chars] || 900)
    page = hits |> Enum.drop(offset) |> Enum.take(limit)
    unjudged = Enum.reject(scored, & &1.score)
    page_unjudged? = hits == []
    unjudged_offset = if page_unjudged?, do: offset, else: 0
    page_total = if page_unjudged?, do: length(unjudged), else: length(hits)

    {:ok,
     %{
       question: question,
       results: Enum.map(page, show),
       total: length(hits),
       next_offset: if(offset + limit < page_total, do: offset + limit),
       nearest:
         if(hits == [],
           do: judged |> Enum.take(@nearest) |> Enum.map(show),
           else: []
         ),
       unjudged: unjudged |> Enum.drop(unjudged_offset) |> Enum.take(limit) |> Enum.map(show),
       unjudged_total: length(unjudged),
       candidates: length(shortlist),
       threshold: threshold,
       judge: judge,
       searches_incomplete: Enum.count(searches, &elem(&1, 1))
     }}
  end

  # Reciprocal rank across the phrasings' lists; the first copy of a passage keeps its fields.
  defp fuse(lists) do
    lists
    |> Enum.flat_map(fn list -> Enum.with_index(list, 1) end)
    |> Enum.reduce(%{}, fn {r, rank}, acc ->
      Map.update(acc, r.chunk_id, Map.put(r, :fused, 1 / (60 + rank)), fn seen ->
        %{
          seen
          | fused: seen.fused + 1 / (60 + rank),
            duplicates: max(seen.duplicates, r.duplicates)
        }
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&(-&1.fused))
  end

  # Words worth finding in a passage: from the question and phrasings, 4+ letters, not filler.
  defp terms(queries) do
    queries
    |> Enum.join(" ")
    |> String.downcase()
    |> then(&Regex.scan(~r/[\p{L}\p{N}][\p{L}\p{N}_.\-\/]{3,}/u, &1))
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, "."))
    |> Enum.reject(&(&1 in @stop))
    |> Enum.uniq()
    |> Enum.take(40)
  end

  defp present(r, terms, chars) do
    %{
      chunk_id: r.chunk_id,
      score: r.score && Float.round(r.score, 3),
      kind: r.kind,
      occurred_at: r.occurred_at,
      machine: r.machine,
      project: r.project,
      tool_name: r.tool_name,
      duplicates: r.duplicates,
      document: Map.take(r.document, [:session_id, :title, :parent_session_id]),
      excerpt: excerpt(r.text, terms, chars),
      chars: String.length(r.text)
    }
  end

  @doc false
  # The `chars` of `text` holding the most question words (a long chunk's answer is often deep in it).
  def excerpt(text, terms, chars) do
    if String.length(text) <= chars do
      text
    else
      hits =
        case terms do
          [] ->
            []

          _ ->
            Regex.scan(Regex.compile!(Enum.map_join(terms, "|", &Regex.escape/1), "iu"), text,
              return: :index
            )
        end
        |> Enum.map(fn [{at, _}] -> at end)

      # Byte offsets; the window is measured in bytes too, then trimmed to whole characters.
      best = best_window(hits, chars)
      start = max(0, min(best - 100, byte_size(text) - chars))
      window = binary_part(text, start, min(chars, byte_size(text) - start)) |> whole_chars()
      window = String.slice(window, 0, chars)

      if(start > 0, do: "…", else: "") <>
        window <> if(start + byte_size(window) < byte_size(text), do: "…", else: "")
    end
  end

  defp best_window([], _), do: 0

  defp best_window(hits, chars) do
    hits = List.to_tuple(hits)
    n = tuple_size(hits)

    {best, _, _} =
      Enum.reduce(0..(n - 1), {elem(hits, 0), 0, 0}, fn i, {best, count, j} ->
        j = Enum.find(j..i, &(elem(hits, &1) > elem(hits, i) - chars + 200)) || i
        if i - j + 1 > count, do: {elem(hits, j), i - j + 1, j}, else: {best, count, j}
      end)

    best
  end

  # Drop a cut character at either end of a byte slice.
  defp whole_chars(bin) do
    bin = drop_leading_continuations(bin)
    trim_invalid_tail(bin, 3)
  end

  defp drop_leading_continuations(<<b, rest::binary>>) when Bitwise.band(b, 0xC0) == 0x80,
    do: drop_leading_continuations(rest)

  defp drop_leading_continuations(bin), do: bin

  defp trim_invalid_tail(bin, 0), do: bin

  defp trim_invalid_tail(bin, n) do
    if String.valid?(bin),
      do: bin,
      else: trim_invalid_tail(binary_part(bin, 0, byte_size(bin) - 1), n - 1)
  end
end
