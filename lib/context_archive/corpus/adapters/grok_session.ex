defmodule ContextArchive.Corpus.Adapters.GrokSession do
  @moduledoc """
  Adapter for Grok CLI sessions (source kind `grok-sessions`), shipped from
  `~/.grok/sessions` (paths are relative to that root):

    * `<encoded-cwd>/<session-id>/updates.jsonl` - a session: Grok's log of ACP session
      updates, one JSON object per line, appended as the session runs and replayed by
      Grok to resume it. `<encoded-cwd>` is the working directory, URL-encoded (a slug
      and a hash instead when that would exceed 255 bytes; then there is no project).
    * the session's other files (`chat_history.jsonl`, the model's copy with the system
      prompt; `events.jsonl`, telemetry; `summary.json`) are not shipped.

  There is no header line: the session id comes from the path. Subagent children and
  forks are sessions of their own in the same tree. A fork starts with a copy of its
  parent's updates, whose event ids (`<session-id>-<n>`) still name the session they
  came from, so that session is its parent. A subagent child's file never names its
  parent (only the parent's `subagent_spawned` line and `subagents/` folder do), so a
  child has no parent here.

  `session/update` lines become Pi-shaped entries for the `Chunker` (see `to_pi/1`):
  what the user typed, the agent's text and thoughts, each tool call (its first
  `tool_call` line) and each tool result (the `tool_call_update` that completes it).
  Hook runs, turn usage, plans, subagent lifecycle and in-progress tool updates stay
  records without chunks. Grok also keeps bash output as a JSON array of byte values
  (`rawOutput.output`); the text comes from the same result's content instead.
  """

  @record_kind "grok-entry"
  @document_kind "grok-session"
  @updates "updates.jsonl"
  @uuid ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
  @event_id ~r/^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})-\d+$/
  @final ["completed", "failed"]

  def record_kind, do: @record_kind
  def document_kind, do: @document_kind

  @doc "Whether a stream path is a Grok session's update log."
  def session_path?(path) do
    case Path.split(path) do
      [_group, session, @updates] -> Regex.match?(@uuid, session)
      _ -> false
    end
  end

  @doc "Document attributes from the path and the first lines."
  def document_info([], _path), do: {:error, :no_header_yet}

  def document_info([first | _] = lines, path) do
    [group, id, @updates] = Path.split(path)

    # A fork's copied lines come first; the last session they name is its parent.
    parent =
      lines
      |> Enum.map(&origin/1)
      |> Enum.reject(&(is_nil(&1) or &1 == id))
      |> List.last()

    model = Enum.find_value(lines, &get_in(&1, ["params", "update", "_meta", "modelId"]))

    {:ok,
     %{
       kind: @document_kind,
       external_id: id,
       project: project(group),
       parent_external_id: parent,
       # When the file began: a fork's copied lines carry the time of the fork.
       started_at: unix(first["timestamp"], :second) || time(first),
       metadata:
         %{"path" => path, "forked_from" => parent, "model" => model}
         |> Map.reject(fn {_k, v} -> is_nil(v) end)
     }}
  end

  def header?(_entry), do: false

  @doc "Record attributes for one decoded line."
  def record_info(entry) do
    u = update(entry)
    su = u["sessionUpdate"]

    %{
      kind: @record_kind,
      external_id: get_in(entry, ["params", "_meta", "eventId"]),
      parent_external_id: nil,
      entry_type: su || entry["method"],
      role: role(su, u),
      tool_name: if(su == "tool_call", do: call_name(u), else: result_tool(u)),
      is_error: error?(u),
      occurred_at: time(entry)
    }
  end

  def title(_entry), do: nil

  @doc "The Pi-shaped entry the Chunker reads, or nil."
  def to_pi(entry) do
    u = update(entry)
    id = get_in(entry, ["params", "_meta", "eventId"])

    # Blank text (an image, say) makes no chunks.
    case u["sessionUpdate"] do
      "user_message_chunk" ->
        message(%{"role" => "user", "content" => text(u["content"])}, id)

      "agent_message_chunk" ->
        assistant([%{"type" => "text", "text" => text(u["content"])}], id)

      "agent_thought_chunk" ->
        assistant([%{"type" => "thinking", "thinking" => text(u["content"])}], id)

      "tool_call" ->
        assistant([tool_call(u)], id)

      "tool_call_update" ->
        if u["status"] in @final do
          message(
            %{
              "role" => "toolResult",
              "toolName" => result_tool(u),
              "isError" => error?(u),
              "content" => result_text(u)
            },
            id
          )
        end

      _ ->
        nil
    end
  end

  defp update(%{"params" => %{"update" => u}}) when is_map(u), do: u
  defp update(_entry), do: %{}

  defp message(m, id), do: %{"type" => "message", "id" => id, "message" => m}
  defp assistant(content, id), do: message(%{"role" => "assistant", "content" => content}, id)

  defp role("user_message_chunk", _u), do: "user"

  defp role(su, _u) when su in ["agent_message_chunk", "agent_thought_chunk", "tool_call"],
    do: "assistant"

  defp role("tool_call_update", u), do: if(u["status"] in @final, do: "toolResult")
  defp role(_su, _u), do: nil

  # Grok's own name for the tool (`x.ai/tool`), or the call's title.
  defp call_name(u), do: get_in(u, ["_meta", "x.ai/tool", "name"]) || u["title"]

  defp tool_call(u) do
    args = if is_map(u["rawInput"]), do: u["rawInput"], else: %{}

    {name, args} =
      case {call_name(u), args} do
        {"run_terminal_command", %{"command" => c}} ->
          {"bash", %{"command" => c}}

        {"read_file", %{"target_file" => p}} ->
          {"read", %{"path" => p}}

        {"write", %{"file_path" => p} = a} ->
          {"write", Map.put(a, "path", p)}

        {"search_replace", %{"file_path" => p} = a} ->
          {"edit", Map.put(a, "path", p)}

        {"spawn_subagent", a} ->
          {"subagent", %{"agent" => a["subagent_type"], "task" => a["description"]}}

        # An MCP tool, e.g. executor__execute, called through Grok's use_tool.
        {"use_tool", %{"tool_name" => t} = a} when is_binary(t) ->
          {t, a["tool_input"] || a}

        {name, a} ->
          {name || "tool", a}
      end

    %{"type" => "toolCall", "id" => u["toolCallId"], "name" => name, "arguments" => args}
  end

  # The tool behind a result, named so the Chunker digests bash and MCP output and embeds
  # subagent results like Pi's.
  defp result_tool(%{"rawOutput" => %{"type" => type}}) do
    case type do
      "Bash" -> "bash"
      "MCP" -> "mcp"
      "SubagentCompleted" -> "subagent"
      "ReadFile" -> "read"
      _ -> nil
    end
  end

  defp result_tool(_u), do: nil

  defp error?(%{"sessionUpdate" => "tool_call_update", "status" => status} = u)
       when status in @final do
    out = if is_map(u["rawOutput"]), do: u["rawOutput"], else: %{}

    status == "failed" or
      (out["type"] == "Bash" and
         (out["exit_code"] not in [0, nil] or out["timed_out"] == true or
            out["signal"] != nil)) or
      (out["type"] == "MCP" and is_map(out["output"]) and
         not Map.has_key?(out["output"], "OkayOutput"))
  end

  defp error?(_u), do: false

  # What the tool returned: the result's text content (what Grok shows), else the text
  # Grok gave the model (bash's `output_for_prompt` holds the exit code even when the
  # command printed nothing), else the first text in the raw output.
  defp result_text(u) do
    case text(u["content"]) do
      "" -> raw_text(u["rawOutput"])
      t -> t
    end
  end

  # Where the text is: bash, MCP (`output` holds OkayOutput or an error variant), tool
  # search, subagents. Nested maps (EditsApplied, FileContent) are searched the same way;
  # the byte-array copy of bash output is never text.
  @raw_keys ~w(output_for_prompt tool_output_for_prompt OkayOutput content output text)
  # Fields that name or locate the tool rather than hold what it returned.
  @raw_meta ~w(type variant tool_name server_name subagent_id subagent_type command
               current_dir description absolute_path output_file worktree_path resume_from_hint)

  defp raw_text(out) when is_map(out) do
    Enum.find_value(@raw_keys, &nonblank(raw_text(out[&1]))) ||
      Enum.find_value(out, fn {k, v} -> k not in @raw_meta and nonblank(raw_text(v)) end) ||
      ""
  end

  defp raw_text(s) when is_binary(s), do: s
  defp raw_text(_), do: ""

  defp nonblank(""), do: nil
  defp nonblank(s), do: s

  # Text of ACP content: a block (`{"type":"text"}`), a tool-call content item
  # (`{"type":"content","content":{...}}`) or a list of either; diffs, images and
  # terminals are left out.
  defp text(%{"type" => "text", "text" => t}) when is_binary(t), do: t
  defp text(%{"type" => "content", "content" => c}), do: text(c)

  defp text(items) when is_list(items),
    do: items |> Enum.map(&text/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n")

  defp text(_), do: ""

  # "<session-id>-<n>": the session this update was first written in.
  defp origin(line) do
    with id when is_binary(id) <- get_in(line, ["params", "_meta", "eventId"]),
         [_, session] <- Regex.run(@event_id, id) do
      session
    else
      _ -> nil
    end
  end

  # "%2FUsers%2Fme%2Fdev%2Fagents" -> "/Users/me/dev/agents"; a slug (long paths) -> nil.
  defp project(group) do
    case URI.decode(group) do
      "/" <> _ = cwd -> cwd
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # The agent's time for the update; copied lines in a fork keep their original one.
  defp time(entry) do
    unix(get_in(entry, ["params", "_meta", "agentTimestampMs"]), :millisecond) ||
      unix(entry["timestamp"], :second)
  end

  defp unix(n, unit) when is_integer(n) do
    case DateTime.from_unix(n, unit) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp unix(_n, _unit), do: nil
end
