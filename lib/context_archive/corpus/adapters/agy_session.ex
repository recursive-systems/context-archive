defmodule ContextArchive.Corpus.Adapters.AgySession do
  @moduledoc """
  Adapter for Antigravity CLI (agy) conversations (source kind `agy-sessions`).

  agy keeps each conversation as SQLite with protobuf steps, so the machine exports it first:
  a separate exporter script (not in this repo) decodes each finished step by field name (with the
  schema compiled into the agy binary) into `<conversation-id>.jsonl` under
  `~/.local/state/agy-sessions/conversations`, the shipper root (paths are that file name):

    * `{"type":"conversation"}` first: id, workspace, parent conversation, agent
    * `{"type":"step","idx":n,"step":{...}}` per step: `type`, `status`, `metadata`
      (created_at, the tool call that produced it) and one content field: `user_input`,
      `planner_response` (thinking, response, tool_calls), `generic` (a tool's args and result)...
    * `{"type":"title"}` whenever agy's title for it changes

  Steps become Pi-shaped entries for the `Chunker` (see `to_pi/1`): what the user typed, the
  agent's thinking and reply, each tool call (run_command, view_file, write_to_file,
  replace_file_content and MCP tools named like Pi's), and each result (a non-zero exit or a
  step that ended in error is an error). Other steps stay records without chunks.
  """

  @record_kind "agy-entry"
  @document_kind "agy-session"
  @uuid ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.jsonl$/

  def record_kind, do: @record_kind
  def document_kind, do: @document_kind

  @doc "Whether a stream path is an exported agy conversation."
  def session_path?(path), do: Regex.match?(@uuid, path)

  @doc "Document attributes from the header line (and the first step's time)."
  def document_info([], _path), do: {:error, :no_header_yet}

  def document_info([%{"type" => "conversation", "id" => id} = h | rest], path) do
    started = Enum.find_value(rest, &time(&1["step"]))

    {:ok,
     %{
       kind: @document_kind,
       external_id: id,
       project: h["workspace"],
       parent_external_id: h["parent"],
       started_at: started,
       metadata:
         %{"path" => path, "agent" => h["agent"], "nesting_depth" => h["nesting_depth"]}
         |> Map.reject(fn {_k, v} -> v in [nil, 0] end)
     }}
  end

  def document_info(_lines, _path), do: {:error, :not_a_session_header}

  def header?(%{"type" => "conversation"}), do: true
  def header?(_), do: false

  @doc "Record attributes for one decoded line."
  def record_info(%{"type" => "step", "step" => s} = e) when is_map(s) do
    %{
      kind: @record_kind,
      external_id: to_string(e["idx"]),
      parent_external_id: nil,
      entry_type: kind(s),
      role: role(s),
      tool_name: tool_call(s)["name"],
      is_error: error?(s),
      occurred_at: time(s)
    }
  end

  def record_info(e) do
    %{
      kind: @record_kind,
      external_id: nil,
      parent_external_id: nil,
      entry_type: e["type"],
      role: nil,
      tool_name: nil,
      is_error: false,
      occurred_at: nil
    }
  end

  @doc "agy's title for the conversation."
  def title(%{"type" => "title", "title" => t}) when is_binary(t) and t != "", do: t
  def title(_), do: nil

  @doc "The Pi-shaped entry the Chunker reads, or nil."
  def to_pi(%{"type" => "step", "idx" => idx, "step" => s}) when is_map(s) do
    id = to_string(idx)

    case s do
      %{"user_input" => u} when is_map(u) ->
        message(%{"role" => "user", "content" => user_text(u)}, id)

      %{"planner_response" => p} when is_map(p) ->
        thinking =
          if is_binary(p["thinking"]),
            do: [%{"type" => "thinking", "thinking" => p["thinking"]}],
            else: []

        text =
          if is_binary(p["response"]),
            do: [%{"type" => "text", "text" => p["response"]}],
            else: []

        calls = for c <- List.wrap(p["tool_calls"]), is_map(c), do: call(c)
        message(%{"role" => "assistant", "content" => thinking ++ text ++ calls}, id)

      %{"generic" => g} when is_map(g) ->
        message(
          %{
            "role" => "toolResult",
            "toolName" => result_tool(tool_call(s)["name"]),
            "isError" => error?(s),
            "content" => result_text(g)
          },
          id
        )

      _ ->
        nil
    end
  end

  def to_pi(_entry), do: nil

  defp message(m, id), do: %{"type" => "message", "id" => id, "message" => m}

  # CORTEX_STEP_TYPE_PLANNER_RESPONSE -> planner_response
  defp kind(%{"type" => "CORTEX_STEP_TYPE_" <> t}), do: String.downcase(t)
  defp kind(%{"type" => t}), do: to_string(t)
  defp kind(_), do: nil

  defp role(%{"user_input" => _}), do: "user"
  defp role(%{"planner_response" => _}), do: "assistant"
  defp role(%{"generic" => _}), do: "toolResult"
  defp role(_), do: nil

  defp tool_call(s) do
    case get_in(s, ["metadata", "tool_call"]) do
      %{} = c -> c
      _ -> %{}
    end
  end

  defp user_text(%{"user_response" => t}) when is_binary(t) and t != "", do: t

  defp user_text(u) do
    u["items"]
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp call(c) do
    args =
      case Jason.decode(c["arguments_json"] || "") do
        {:ok, %{} = a} -> Map.drop(a, ["toolAction", "toolSummary"])
        _ -> %{"arguments" => c["arguments_json"]}
      end

    {name, args} =
      case {c["name"], args} do
        {"run_command", %{"CommandLine" => cmd}} ->
          {"bash", %{"command" => cmd}}

        {"view_file", %{"AbsolutePath" => p}} ->
          {"read", %{"path" => p}}

        {"write_to_file", %{"TargetFile" => p} = a} ->
          {"write", Map.put(a, "path", p)}

        {n, %{"TargetFile" => p} = a}
        when n in ["replace_file_content", "multi_replace_file_content"] ->
          {"edit", Map.put(a, "path", p)}

        {"call_mcp_tool", %{"ServerName" => srv, "ToolName" => tool} = a} ->
          {"#{srv}__#{tool}", mcp_args(a["Arguments"])}

        {n, a} ->
          {n || "tool", a}
      end

    %{"type" => "toolCall", "id" => c["id"], "name" => name, "arguments" => args}
  end

  defp mcp_args(a) when is_map(a), do: a

  defp mcp_args(a) when is_binary(a) do
    case Jason.decode(a) do
      {:ok, %{} = m} -> m
      _ -> %{"arguments" => a}
    end
  end

  defp mcp_args(_), do: %{}

  # Named so the Chunker digests bash and MCP output like Pi's.
  defp result_tool("run_command"), do: "bash"
  defp result_tool("call_mcp_tool"), do: "mcp"
  defp result_tool("view_file"), do: "read"
  defp result_tool(_), do: nil

  defp result_text(%{"result" => %{"result" => t}}) when is_binary(t), do: t
  defp result_text(_), do: ""

  defp error?(s) do
    s["status"] == "CORTEX_STEP_STATUS_ERROR" or
      (tool_call(s)["name"] == "run_command" and
         nonzero_exit?(get_in(s, ["generic", "result", "result"])))
  end

  defp nonzero_exit?(t) when is_binary(t) do
    case Regex.run(~r/exited with code (-?\d+)/, t) do
      [_, code] -> code != "0"
      _ -> false
    end
  end

  defp nonzero_exit?(_), do: false

  defp time(%{"metadata" => %{"created_at" => %{"seconds" => s} = ts}}) when is_integer(s) do
    nanos = if is_integer(ts["nanos"]), do: ts["nanos"], else: 0

    case DateTime.from_unix(s * 1_000_000 + div(nanos, 1000), :microsecond) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp time(_), do: nil
end
