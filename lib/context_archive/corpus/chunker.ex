defmodule ContextArchive.Corpus.Chunker do
  @moduledoc """
  Turns one Pi session entry into chunks, following the archive's embedding policy:

    * embedded: user text, assistant text, thinking, tool-call summaries, every tool
      error, subagent results, compaction/branch summaries, extension messages, and a
      head+tail digest of `bash` / tool-gateway / job-log output
    * keyword-only: everything else (file reads, listings, full long outputs, edit and
      write payloads), so exact strings stay findable without paying for vectors; also
      extension messages whose `customType` is configured keyword-only
      (`CONTEXT_ARCHIVE_KEYWORD_ONLY_TYPES`): machine-written records such as event logs

  Embedded text is split into parts of at most #{900} characters with #{100} characters
  of overlap, which keeps each part within the embedding model's 256-token window.
  """

  @embed_chars 900
  @overlap 100
  @keyword_cap 100_000
  @digest_head 600
  @digest_tail 300
  @max_embedded_parts 8
  @digest_tools ~w(bash executor_execute job_logs job_status job_wait mcp)

  @type chunk :: %{
          kind: atom,
          part: non_neg_integer,
          text: String.t(),
          embed?: boolean,
          metadata: map
        }

  @doc "Chunks for a decoded Pi entry (map). Returns a list of chunk maps."
  @spec chunks(map) :: [chunk]
  def chunks(%{"type" => "message", "message" => %{"role" => role} = m}),
    do: message_chunks(role, m)

  def chunks(%{"type" => type, "summary" => summary})
      when type in ["compaction", "branch_summary"] and is_binary(summary),
      do: embedded(:summary, summary, %{"entry_type" => type})

  def chunks(%{"type" => "custom_message", "content" => content} = e) do
    text = content_text(content)
    meta = %{"custom_type" => e["customType"]}

    cond do
      e["customType"] not in keyword_only_types() ->
        embedded(:extension_message, text, meta) |> Enum.take(3)

      String.trim(text) == "" ->
        []

      true ->
        [keyword(:extension_message, 0, text, meta)]
    end
  end

  def chunks(_entry), do: []

  defp message_chunks("user", m),
    do: embedded(:user, content_text(m["content"]), %{"role" => "user"})

  defp message_chunks("assistant", m) do
    blocks = List.wrap(m["content"])

    text =
      blocks
      |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
      |> Enum.map_join("\n", &(&1["text"] || ""))

    thinking =
      blocks
      |> Enum.filter(&(is_map(&1) and &1["type"] == "thinking"))
      |> Enum.map_join("\n", &(&1["thinking"] || ""))

    calls = Enum.filter(blocks, &(is_map(&1) and &1["type"] == "toolCall"))

    error =
      if m["stopReason"] == "error" and is_binary(m["errorMessage"]),
        do:
          embedded(:tool_error, "model error: " <> m["errorMessage"], %{
            "role" => "assistant",
            "model" => m["model"]
          }),
        else: []

    embedded(:assistant, text, %{"role" => "assistant", "model" => m["model"]}) ++
      embedded(:thinking, thinking, %{"role" => "assistant", "model" => m["model"]}) ++
      tool_call_chunks(calls) ++ error
  end

  defp message_chunks(role, m) when role in ["toolResult", "bashExecution"] do
    tool = m["toolName"] || if(role == "bashExecution", do: "bash", else: nil)
    text = content_text(m["content"]) <> output_text(m)
    meta = %{"role" => role, "tool_name" => tool, "is_error" => m["isError"] == true}

    cond do
      String.trim(text) == "" ->
        []

      m["isError"] == true ->
        embedded(:tool_error, text, meta) ++ overflow(:tool_error, text, meta)

      tool == "subagent" ->
        embedded(:subagent_result, text, meta) ++ overflow(:subagent_result, text, meta)

      tool in @digest_tools ->
        digest(text, meta)

      true ->
        [keyword(:tool_output, 0, text, meta)]
    end
  end

  defp message_chunks("custom", m),
    do:
      embedded(:extension_message, content_text(m["content"]), %{"role" => "custom"})
      |> Enum.take(3)

  # System prompts and anything unknown are kept as records, not search chunks.
  defp message_chunks(_role, _m), do: []

  defp output_text(%{"output" => out}) when is_binary(out), do: out
  defp output_text(_), do: ""

  defp tool_call_chunks(calls) do
    calls
    |> Enum.with_index()
    |> Enum.flat_map(fn {call, i} ->
      name = call["name"] || "tool"
      args = call["arguments"] || %{}
      summary = truncate("#{name}: #{tool_detail(name, args)}", @embed_chars)
      meta = %{"tool_name" => name, "tool_call_id" => call["id"]}
      full = if is_map(args), do: Jason.encode!(args), else: to_string(args)

      [%{kind: :tool_call, part: i * 2, text: summary, embed?: true, metadata: meta}] ++
        if(String.length(full) > String.length(summary),
          do: [keyword(:tool_call, i * 2 + 1, full, meta)],
          else: []
        )
    end)
  end

  defp tool_detail("bash", %{"command" => c}), do: c

  defp tool_detail(n, a) when n in ["read", "write", "edit", "ls", "find"] and is_map(a),
    do: Enum.map_join([a["path"], a["pattern"]], " ", &(&1 || ""))

  defp tool_detail("grep", a) when is_map(a), do: "#{a["pattern"]} #{a["path"]}"

  defp tool_detail("subagent", a) when is_map(a),
    do: Enum.join(Enum.reject([a["agent"], a["task"], a["workflow"]], &is_nil/1), ": ")

  defp tool_detail(_, a) when is_map(a), do: Jason.encode!(a)
  defp tool_detail(_, a), do: to_string(a)

  defp digest(text, meta) do
    if String.length(text) <= @digest_head + @digest_tail do
      [%{kind: :tool_output, part: 0, text: text, embed?: true, metadata: meta}]
    else
      head = String.slice(text, 0, @digest_head)
      tail = String.slice(text, -@digest_tail, @digest_tail)

      [
        %{
          kind: :tool_output,
          part: 0,
          text: head <> "\n…\n" <> tail,
          embed?: true,
          metadata: Map.put(meta, "digest", true)
        },
        keyword(:tool_output, 1, text, meta)
      ]
    end
  end

  # When embedded parts were capped, keep the complete text keyword-searchable too.
  defp overflow(kind, text, meta) do
    if length(split(text)) > @max_embedded_parts,
      do: [keyword(kind, @max_embedded_parts, text, meta)],
      else: []
  end

  @doc "Extension message types stored keyword-only (`CONTEXT_ARCHIVE_KEYWORD_ONLY_TYPES`)."
  def keyword_only_types,
    do: Application.get_env(:context_archive, :keyword_only_custom_types, [])

  defp keyword(kind, part, text, meta),
    do: %{
      kind: kind,
      part: part,
      text: truncate(text, @keyword_cap),
      embed?: false,
      metadata: meta
    }

  defp embedded(kind, text, meta) do
    text
    |> split()
    |> Enum.take(@max_embedded_parts)
    |> Enum.with_index()
    |> Enum.map(fn {part_text, i} ->
      %{kind: kind, part: i, text: part_text, embed?: true, metadata: meta}
    end)
  end

  @doc "Splits text into overlapping parts of at most #{@embed_chars} characters. Blank text gives []."
  def split(text) when is_binary(text) do
    text = String.trim(text)
    len = String.length(text)

    cond do
      len == 0 ->
        []

      len <= @embed_chars ->
        [text]

      true ->
        for start <- 0..(len - 1)//(@embed_chars - @overlap),
            start < len - @overlap,
            do: String.slice(text, start, @embed_chars)
    end
  end

  def split(_), do: []

  @doc "Plain text of Pi message content (string or list of blocks)."
  def content_text(content) when is_binary(content), do: content

  def content_text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end

  def content_text(_), do: ""

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max), else: text
  end
end
