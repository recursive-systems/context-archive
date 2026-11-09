defmodule ContextArchive.Corpus.Adapters.ClaudeSession do
  @moduledoc """
  Adapter for Claude Code session files (source kind `claude-sessions`), shipped from
  `~/.claude/projects` (paths are relative to that root):

    * `<project-dir>/<session-uuid>.jsonl` - a session
    * `<project-dir>/<session-uuid>/subagents/agent-<id>.jsonl` - a subagent's
      transcript; its parent is that session
    * `memory/`, `tool-results/` and anything else - archived raw, not parsed

  There is no header line: the session id comes from the file name and the project from
  the first line that carries a `cwd`. Lines with a `message` become Pi-shaped entries
  for the `Chunker` (see `to_pi/1`); the rest (hook attachments, cost and mode state,
  file-history snapshots) are kept as records without chunks.
  """

  alias ContextArchive.Corpus.Adapters.PiSession

  @record_kind "claude-entry"
  @document_kind "claude-session"
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  def record_kind, do: @record_kind
  def document_kind, do: @document_kind

  @doc "Whether a stream path is a Claude Code session or subagent transcript."
  def session_path?(path) do
    case Path.split(path) do
      [_project, file] ->
        session_file?(file)

      [_project, session, "subagents", "agent-" <> _ = file] ->
        uuid?(session) and String.ends_with?(file, ".jsonl")

      _ ->
        false
    end
  end

  defp session_file?(file),
    do: String.ends_with?(file, ".jsonl") and uuid?(Path.basename(file, ".jsonl"))

  defp uuid?(s), do: Regex.match?(@uuid, s)

  @doc "Document attributes from the path and the first lines."
  def document_info([], _path), do: {:error, :no_header_yet}

  def document_info(lines, path) do
    first = Enum.find(lines, &is_binary(&1["cwd"]))
    started = Enum.find_value(lines, &PiSession.parse_time(&1["timestamp"]))

    {id, parent, meta} =
      case Path.split(path) do
        [_project, session, "subagents", file] ->
          {Path.basename(file, ".jsonl"), session, %{"subagent_child" => true}}

        [_project, file] ->
          {Path.basename(file, ".jsonl"), nil, %{}}
      end

    {:ok,
     %{
       kind: @document_kind,
       external_id: id,
       project: first && first["cwd"],
       parent_external_id: parent,
       started_at: started,
       metadata:
         Map.merge(meta, %{
           "path" => path,
           "version" => first && first["version"],
           "git_branch" => first && first["gitBranch"]
         })
     }}
  end

  def header?(_entry), do: false

  @doc "Record attributes for one decoded line."
  def record_info(entry) do
    message = if is_map(entry["message"]), do: entry["message"], else: %{}

    %{
      kind: @record_kind,
      external_id: entry["uuid"],
      parent_external_id: entry["parentUuid"],
      entry_type: entry["type"],
      role: message["role"],
      tool_name: nil,
      is_error: entry["isApiErrorMessage"] == true or tool_error?(message),
      occurred_at: PiSession.parse_time(entry["timestamp"])
    }
  end

  @doc "Session title: Claude Code's generated or custom title."
  def title(%{"type" => "ai-title", "aiTitle" => t}) when is_binary(t) and t != "", do: t
  def title(%{"type" => "custom-title", "customTitle" => t}) when is_binary(t) and t != "", do: t
  def title(%{"type" => "summary", "summary" => t}) when is_binary(t) and t != "", do: t
  def title(_), do: nil

  @doc """
  The Pi-shaped entry the Chunker reads, or nil: user text, assistant text/thinking/
  tool calls, tool results (one entry per line, all results of the line together),
  compaction summaries, and API errors.
  """
  def to_pi(%{"isCompactSummary" => true, "message" => %{"content" => c}}),
    do: %{"type" => "compaction", "summary" => text(c)}

  def to_pi(%{"type" => "user", "message" => %{"content" => c}} = e) when is_binary(c),
    do: message(%{"role" => "user", "content" => c}, e)

  def to_pi(%{"type" => "user", "message" => %{"content" => blocks}} = e) when is_list(blocks) do
    results = Enum.filter(blocks, &(is_map(&1) and &1["type"] == "tool_result"))

    if results == [] do
      message(%{"role" => "user", "content" => text(blocks)}, e)
    else
      message(
        %{
          "role" => "toolResult",
          "toolName" => tool_name(e),
          "isError" => Enum.any?(results, &(&1["is_error"] == true)),
          "content" => Enum.map_join(results, "\n", &text(&1["content"]))
        },
        e
      )
    end
  end

  def to_pi(%{"type" => "assistant", "message" => %{"content" => blocks} = m} = e)
      when is_list(blocks) do
    content =
      Enum.flat_map(blocks, fn
        %{"type" => "text", "text" => t} -> [%{"type" => "text", "text" => t}]
        %{"type" => "thinking", "thinking" => t} -> [%{"type" => "thinking", "thinking" => t}]
        %{"type" => "tool_use"} = b -> [tool_call(b)]
        _ -> []
      end)

    error =
      if e["isApiErrorMessage"] == true,
        do: %{"stopReason" => "error", "errorMessage" => text(blocks)},
        else: %{}

    message(
      Map.merge(%{"role" => "assistant", "model" => m["model"], "content" => content}, error),
      e
    )
  end

  def to_pi(_entry), do: nil

  defp message(m, e), do: %{"type" => "message", "id" => e["uuid"], "message" => m}

  # Bash results carry stdout/stderr in toolUseResult; naming them lets the Chunker digest them.
  defp tool_name(%{"toolUseResult" => %{"stdout" => _}}), do: "bash"
  defp tool_name(_), do: nil

  defp tool_call(%{"name" => name, "input" => input} = b) do
    {name, args} =
      case {name, input} do
        {"Bash", %{"command" => c}} -> {"bash", %{"command" => c}}
        {"Read", %{"file_path" => p}} -> {"read", %{"path" => p}}
        {"Write", %{"file_path" => p} = a} -> {"write", Map.put(a, "path", p)}
        {"Edit", %{"file_path" => p} = a} -> {"edit", Map.put(a, "path", p)}
        {"Grep", %{"pattern" => _} = a} -> {"grep", a}
        {"Task", a} -> {"subagent", %{"agent" => a["subagent_type"], "task" => a["description"]}}
        _ -> {name, input}
      end

    %{"type" => "toolCall", "id" => b["id"], "name" => name, "arguments" => args}
  end

  defp tool_call(b), do: %{"type" => "toolCall", "id" => b["id"], "name" => b["name"] || "tool"}

  defp tool_error?(%{"content" => blocks}) when is_list(blocks),
    do:
      Enum.any?(blocks, &(is_map(&1) and &1["type"] == "tool_result" and &1["is_error"] == true))

  defp tool_error?(_), do: false

  # Text of Claude content: a string, or blocks of text (images and others left out).
  defp text(c) when is_binary(c), do: c

  defp text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      s when is_binary(s) -> [s]
      %{"type" => "text", "text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp text(_), do: ""
end
