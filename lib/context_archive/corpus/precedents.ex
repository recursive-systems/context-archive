defmodule ContextArchive.Corpus.Precedents do
  @moduledoc """
  Precedents: decisions the owner states, recorded by agents and verified by the archive.

  An agent records one by writing a fenced block in its own assistant message:

      ```precedent
      {"topic": "deploys", "question": "Deploy on Fridays?",
       "decision": "No deploys on Fridays.", "reason": "optional",
       "supersedes": "<id of the precedent this replaces, optional>"}
      ```

  The archive accepts it only when the decision, whitespace-normalized, appears verbatim in
  a message the human typed in the same session, at or before the recording (see
  `human_typed/1` and each adapter's `human_text/1` for what counts as typed by the human).
  A decision under #{4} words ("yes", "go ahead") must also be bound to its question: the
  question appears in that human message or in the assistant turn just before it.
  Subagent sessions have no human messages, so they can never record one.

  A verified precedent becomes a chunk of kind `precedent` on the recording entry (so search,
  find and the `kinds` filter see it like any other passage), stored once even when forked
  sessions copy the entry. Unverified blocks stay ordinary assistant text.

  Precedents are immutable; "current" is computed when read. Precedents joined by the same
  topic (stored lowercased, whitespace-normalized) or by a `supersedes` link form one line; the
  line's newest precedent (by recording time, then id) is current, the rest are its history.
  A `supersedes` link counts only when it names a visible precedent recorded earlier, so
  links can't form cycles; others are reported as unresolved and ignored.
  """
  require Logger

  alias ContextArchive.{Ids, Masking, Repo}
  alias ContextArchive.Corpus.Chunker

  @fence ~r/```precedent[ \t]*\r?\n(.*?)\r?\n[ \t]*```/s
  @short_decision_words 4

  # Messages in a user role that the human did not type: Herdr messages from other agents,
  # loop prompts, harness notifications and command output, injected context.
  @not_typed [
    "<hc",
    "[loop",
    "<task-notification",
    "<system-reminder",
    "<local-command",
    "<command-",
    "<bash-input",
    "<bash-stdout",
    "<bash-stderr",
    "[Request interrupted",
    "Caveat:",
    "<user_shell_command",
    "<turn_aborted",
    "<subagent_notification",
    "<environment_context",
    "<user_instructions",
    "# AGENTS.md instructions",
    "<permissions instructions",
    "<skills_instructions"
  ]
  # Parts of a typed message the human did not write: pasted text, Herdr messages, reminders.
  @not_typed_parts ~r/<(pasted_content|hc|system-reminder)\b[^>]*>.*?(<\/\1>|\z)/s

  ## Recording (at parse time)

  @doc """
  Precedent blocks in `text`: `[{index, attrs}]` for each well-formed block (index counts
  every block in the text, well-formed or not, so ids stay stable).
  """
  def blocks(text) when is_binary(text) do
    @fence
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.with_index()
    |> Enum.flat_map(fn {[json], i} ->
      case Jason.decode(json) do
        {:ok, %{} = b} -> if a = attrs(b), do: [{i, a}], else: []
        _ -> []
      end
    end)
  end

  def blocks(_), do: []

  defp attrs(b) do
    supersedes =
      case b["supersedes"] do
        s when is_binary(s) -> [s]
        l when is_list(l) -> Enum.filter(l, &is_binary/1)
        _ -> []
      end
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    [topic, question, decision] =
      Enum.map([b["topic"] || b["id"], b["question"], b["decision"]], &normalize/1)

    if topic != "" and question != "" and decision != "" do
      %{
        "topic" => String.downcase(topic),
        "question" => String.trim(b["question"]),
        "decision" => String.trim(b["decision"]),
        "reason" => if(normalize(b["reason"]) != "", do: String.trim(b["reason"])),
        "supersedes" => supersedes
      }
    end
  end

  @doc "Text with every run of whitespace made one space, trimmed."
  def normalize(text) when is_binary(text), do: text |> String.split() |> Enum.join(" ")
  def normalize(_), do: ""

  @doc """
  The part of a user message's text the human typed, or nil when the message is not typed
  by the human at all (a Herdr message, a loop prompt, a notification, injected context).
  Pasted text, Herdr messages and system reminders inside a typed message are removed.
  """
  def human_typed(text) when is_binary(text) do
    trimmed = String.trim_leading(text)

    if Enum.any?(@not_typed, &String.starts_with?(trimmed, &1)) do
      nil
    else
      case text |> String.replace(@not_typed_parts, " ") |> String.trim() do
        "" -> nil
        typed -> typed
      end
    end
  end

  def human_typed(_), do: nil

  @doc """
  Verifies the precedent blocks in a parsed slice of `doc` and returns their chunks.
  `rows` are `{entry, record, stream_id, byte_offset}` of the slice, already stored.
  """
  def chunks(adapter, doc, rows) do
    if doc.metadata["subagent_child"] == true do
      []
    else
      Enum.flat_map(rows, fn {entry, record, stream_id, offset} ->
        text = entry |> adapter.to_pi() |> List.wrap() |> Enum.map_join("\n", &assistant_text/1)

        case blocks(text) do
          [] ->
            []

          blocks ->
            turns = conversation_before(adapter, doc, stream_id, offset, record.occurred_at)

            Enum.flat_map(blocks, fn {i, attrs} ->
              case verify(attrs, turns) do
                {:ok, evidence} ->
                  [chunk(doc, record, i, Map.merge(attrs, evidence))]

                :error ->
                  Logger.info("unverified precedent block in record #{record.id} (#{i})")
                  []
              end
            end)
        end
      end)
    end
  end

  defp assistant_text(%{"type" => "message", "message" => %{"role" => "assistant"} = m}),
    do: Chunker.content_text(m["content"])

  defp assistant_text(_), do: ""

  # The session's messages before the recording, oldest first, as {:human, text, entry} or
  # {:assistant, text}: those in the same stream before its byte offset, and those first
  # seen in another stream (an earlier generation of the file) at or before its time.
  defp conversation_before(adapter, doc, stream_id, offset, at) do
    sql = """
    SELECT r.raw, r.external_id, r.occurred_at
    FROM document_records m JOIN records r ON r.id = m.record_id
    WHERE m.document_id = $1 AND r.role IN ('user', 'assistant')
      AND ((m.stream_id = $2 AND m.byte_offset < $3)
           OR (m.stream_id <> $2 AND $4::timestamp IS NOT NULL AND r.occurred_at <= $4))
    ORDER BY (m.stream_id = $2), CASE WHEN m.stream_id = $2 THEN m.byte_offset END,
             r.occurred_at, m.byte_offset
    """

    %{rows: rows} =
      Repo.query!(sql, [Ecto.UUID.dump!(doc.id), Ecto.UUID.dump!(stream_id), offset, at])

    Enum.flat_map(rows, fn [raw, entry_id, occurred_at] ->
      case adapter.human_text(raw) do
        text when is_binary(text) ->
          [{:human, normalize(text), %{"entry_id" => entry_id, "occurred_at" => occurred_at}}]

        nil ->
          case raw |> adapter.to_pi() |> List.wrap() |> Enum.map_join("\n", &assistant_text/1) do
            "" -> []
            text -> [{:assistant, normalize(text)}]
          end
      end
    end)
  end

  # The latest human message holding the decision, preferring one bound to the question.
  defp verify(attrs, turns) do
    decision = normalize(attrs["decision"])
    question = normalize(attrs["question"])

    {matches, _} =
      Enum.reduce(turns, {[], ""}, fn
        {:assistant, text}, {found, turn} ->
          {found, turn <> " " <> text}

        {:human, text, evidence}, {found, turn} ->
          if String.contains?(text, decision) do
            bound? = String.contains?(text, question) or String.contains?(turn, question)
            {[{bound?, evidence} | found], ""}
          else
            {found, ""}
          end
      end)

    short? = length(String.split(decision)) < @short_decision_words

    case Enum.find(matches, &elem(&1, 0)) || (!short? && List.first(matches)) do
      {bound?, evidence} ->
        {:ok,
         %{
           "question_verified" => bound?,
           "evidence_entry_id" => evidence["entry_id"],
           "evidence_at" => iso8601(evidence["occurred_at"])
         }}

      _ ->
        :error
    end
  end

  defp iso8601(at), do: if(at = utc(at), do: DateTime.to_iso8601(at))

  # Timestamps read with raw SQL come back naive; they are UTC.
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(at), do: at

  defp chunk(doc, record, i, p) do
    text =
      Enum.join(
        Enum.reject(
          [
            "Precedent (#{p["topic"]}): #{p["decision"]}",
            "Question: #{p["question"]}",
            p["reason"] && "Reason: #{p["reason"]}"
          ],
          &is_nil/1
        ),
        "\n"
      )

    %{
      id: Ids.uuid("chunk", [record.id, :precedent, i]),
      record_id: record.id,
      document_id: doc.id,
      kind: :precedent,
      part: i,
      text: text,
      embed?: true,
      scope: doc.scope,
      machine: doc.machine,
      project: doc.project,
      occurred_at: record.occurred_at,
      metadata: %{"session_id" => doc.external_id, "precedent" => p}
    }
  end

  ## Reading (current is computed here)

  @doc """
  Lines of precedents visible to `scopes`, newest first: `%{topic, topics, current, history}`.
  Options: `:topic` (only lines with this topic), `:query` (only lines with a precedent
  matching these words, web-search syntax), `:limit`, `:unmasked?`.
  """
  def lines(scopes, opts \\ []) do
    all = load(scopes)
    lines = group(all)

    matching =
      case opts[:query] do
        q when is_binary(q) and q != "" -> matching_ids(scopes, q)
        _ -> nil
      end

    topic = opts[:topic] && opts[:topic] |> normalize() |> String.downcase()

    lines
    |> Enum.filter(fn line ->
      (is_nil(topic) or Enum.any?(line, &(&1.topic_key == topic))) and
        (is_nil(matching) or Enum.any?(line, &MapSet.member?(matching, &1.id)))
    end)
    |> Enum.take(opts[:limit] || 20)
    |> Enum.map(&present_line(&1, opts[:unmasked?]))
  end

  @doc "For search results: `%{precedent_id => %{current: bool, current_id: id}}` for `ids`."
  def status(_scopes, []), do: %{}

  def status(scopes, ids) do
    scopes
    |> load()
    |> group()
    |> Enum.flat_map(fn [current | _] = line ->
      for p <- line,
          p.id in ids,
          do: {p.id, %{current: p.id == current.id, current_id: current.id}}
    end)
    |> Map.new()
  end

  defp load(scopes) do
    sql = """
    SELECT c.id, c.metadata, c.occurred_at, c.machine, c.project, c.scope,
           d.id, d.external_id, d.title, r.external_id
    FROM chunks c
    JOIN documents d ON d.id = c.document_id
    JOIN records r ON r.id = c.record_id
    WHERE c.kind = 'precedent' AND c.scope = ANY($1::text[])
    """

    Repo.query!(sql, [scopes]).rows
    |> Enum.map(fn [id, meta, at, machine, project, scope, did, sid, title, eid] ->
      p = meta["precedent"] || %{}

      %{
        id: Ecto.UUID.load!(id),
        topic: p["topic"],
        topic_key: p["topic"] || "",
        question: p["question"],
        decision: p["decision"],
        reason: p["reason"],
        supersedes: p["supersedes"] || [],
        question_verified: p["question_verified"],
        recorded_at: utc(at),
        machine: machine,
        project: project,
        scope: scope,
        session: %{document_id: Ecto.UUID.load!(did), session_id: sid, title: title},
        entry_id: eid,
        evidence: %{entry_id: p["evidence_entry_id"], occurred_at: p["evidence_at"]}
      }
    end)
  end

  defp order_key(p),
    do: {DateTime.to_unix(p.recorded_at || ~U[1970-01-01 00:00:00Z], :microsecond), p.id}

  # Lines: connected by topic and by resolved supersedes links; each newest first.
  defp group(all) do
    by_id = Map.new(all, &{&1.id, &1})

    edges =
      (all
       |> Enum.group_by(& &1.topic_key)
       |> Enum.flat_map(fn {_, [first | rest]} -> Enum.map(rest, &{first.id, &1.id}) end)) ++
        for p <- all,
            s <- p.supersedes,
            target = by_id[s],
            target && order_key(target) < order_key(p),
            do: {p.id, target.id}

    parents =
      Enum.reduce(edges, Map.new(all, &{&1.id, &1.id}), fn {a, b}, acc -> union(acc, a, b) end)

    all
    |> Enum.group_by(&find(parents, &1.id))
    |> Map.values()
    |> Enum.map(fn line -> Enum.sort_by(line, &order_key/1, :desc) end)
    |> Enum.sort_by(&order_key(hd(&1)), :desc)
  end

  defp find(parents, id) do
    case parents[id] do
      ^id -> id
      parent -> find(parents, parent)
    end
  end

  defp union(parents, a, b) do
    {ra, rb} = {find(parents, a), find(parents, b)}
    if ra == rb, do: parents, else: Map.put(parents, max(ra, rb), min(ra, rb))
  end

  defp matching_ids(scopes, query) do
    sql = """
    SELECT c.id FROM chunks c, websearch_to_tsquery('english', $2) q
    WHERE c.kind = 'precedent' AND c.scope = ANY($1::text[]) AND c.search_vector @@ q
    """

    Repo.query!(sql, [scopes, query]).rows |> MapSet.new(fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp present_line([current | history] = line, unmasked?) do
    %{
      topic: current.topic,
      topics: line |> Enum.map(& &1.topic) |> Enum.uniq(),
      current: present(current, nil, line, unmasked?),
      history:
        Enum.map(history, fn p ->
          by = Enum.find(line, &(p.id in &1.supersedes and order_key(&1) > order_key(p)))
          present(p, (by || current).id, line, unmasked?)
        end)
    }
  end

  defp present(p, superseded_by, line, unmasked?) do
    mask = fn t -> if unmasked? or is_nil(t), do: t, else: Masking.mask(t) end

    resolved? = fn id ->
      Enum.any?(line, &(&1.id == id and order_key(&1) < order_key(p)))
    end

    %{
      id: p.id,
      topic: p.topic,
      question: mask.(p.question),
      decision: mask.(p.decision),
      reason: mask.(p.reason),
      supersedes: p.supersedes,
      unresolved_supersedes: Enum.reject(p.supersedes, resolved?),
      superseded_by: superseded_by,
      question_verified: p.question_verified,
      recorded_at: p.recorded_at,
      machine: p.machine,
      project: p.project,
      session: p.session,
      entry_id: p.entry_id,
      chunk_id: p.id,
      evidence: p.evidence
    }
  end
end
