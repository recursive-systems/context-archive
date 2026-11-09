defmodule ContextArchive.Corpus.Adapters.CodexSession do
  @moduledoc """
  Adapter for Codex session files (source kind `codex-sessions`), shipped from
  `~/.codex/sessions` (`YYYY/MM/DD/rollout-<time>-<thread-id>.jsonl`) and
  `~/.codex/archived_sessions` (`rollout-*.jsonl`, the same files once archived).

  The first line is the header (`"type":"session_meta"`: thread id, cwd, and for forks
  and subagents the parent thread). `response_item` lines carry the conversation and
  become Pi-shaped entries for the `Chunker` (see `to_pi/1`); developer messages and
  injected context (AGENTS.md, environment) are left out like Pi's system prompt.
  `event_msg` lines repeat what `response_item` lines hold, so they stay records only.
  """

  alias ContextArchive.Corpus.Adapters.PiSession

  @record_kind "codex-entry"
  @document_kind "codex-session"
  # Injected context Codex sends as user messages; not what the user typed.
  @injected [
    "# AGENTS.md instructions",
    "<environment_context>",
    "<user_instructions>",
    "<permissions instructions>",
    "<skills_instructions>"
  ]

  def record_kind, do: @record_kind
  def document_kind, do: @document_kind

  @doc "Whether a stream path is a Codex rollout file."
  def session_path?(path) do
    file = Path.basename(path)
    String.starts_with?(file, "rollout-") and String.ends_with?(file, ".jsonl")
  end

  @doc "Document attributes from the header (first line) and the path."
  def document_info([], _path), do: {:error, :no_header_yet}

  def document_info([%{"type" => "session_meta", "payload" => %{"id" => id} = p} = h | _], path) do
    # `source` is "cli", "vscode", ... or, for a spawned subagent, a map naming its parent.
    spawn =
      case p["source"] do
        %{"subagent" => %{"thread_spawn" => s}} when is_map(s) -> s
        _ -> %{}
      end

    parent = p["parent_thread_id"] || spawn["parent_thread_id"] || p["forked_from_id"]

    {:ok,
     %{
       kind: @document_kind,
       external_id: id,
       project: p["cwd"],
       parent_external_id: parent,
       started_at: PiSession.parse_time(p["timestamp"] || h["timestamp"]),
       metadata:
         %{
           "path" => path,
           "cli_version" => p["cli_version"],
           "originator" => p["originator"],
           "forked_from" => p["forked_from_id"],
           "subagent_child" => if(spawn != %{} or p["parent_thread_id"], do: true),
           "agent_nickname" => p["agent_nickname"] || spawn["agent_nickname"]
         }
         |> Map.reject(fn {_k, v} -> is_nil(v) end)
     }}
  end

  def document_info(_lines, _path), do: {:error, :not_a_session_header}

  def header?(%{"type" => "session_meta"}), do: true
  def header?(_), do: false

  @doc "Record attributes for one decoded line."
  def record_info(entry) do
    p = if is_map(entry["payload"]), do: entry["payload"], else: %{}

    %{
      kind: @record_kind,
      external_id: p["id"] || p["call_id"],
      parent_external_id: nil,
      entry_type: Enum.join(Enum.reject([entry["type"], p["type"]], &is_nil/1), ":"),
      role: p["role"],
      tool_name: p["name"],
      is_error: error_output?(p),
      occurred_at: PiSession.parse_time(entry["timestamp"])
    }
  end

  def title(_entry), do: nil

  @doc "The Pi-shaped entry the Chunker reads, or nil."
  def to_pi(%{"type" => "response_item", "payload" => p} = e) when is_map(p), do: item(p, e)

  def to_pi(%{"type" => "compacted", "payload" => %{"message" => m}})
      when is_binary(m) and m != "",
      do: %{"type" => "compaction", "summary" => m}

  def to_pi(_entry), do: nil

  defp item(%{"type" => "message", "role" => "user", "content" => c}, e) do
    text = text(c)
    if injected?(text), do: nil, else: message(%{"role" => "user", "content" => text}, e)
  end

  defp item(%{"type" => "message", "role" => "assistant", "content" => c}, e),
    do:
      message(%{"role" => "assistant", "content" => [%{"type" => "text", "text" => text(c)}]}, e)

  defp item(%{"type" => "reasoning", "summary" => s}, e) when is_list(s) and s != [] do
    thinking = text(s)

    if thinking == "",
      do: nil,
      else:
        message(
          %{
            "role" => "assistant",
            "content" => [%{"type" => "thinking", "thinking" => thinking}]
          },
          e
        )
  end

  defp item(%{"type" => "function_call", "name" => name} = p, e) do
    args =
      case Jason.decode(p["arguments"] || "") do
        {:ok, a} when is_map(a) -> a
        _ -> %{"arguments" => p["arguments"]}
      end

    {name, args} =
      case {name, args} do
        {n, %{"cmd" => c}} when n in ["exec_command", "shell", "local_shell"] ->
          {"bash", %{"command" => c}}

        {n, %{"command" => c}} when n in ["shell", "local_shell"] ->
          {"bash", %{"command" => command(c)}}

        other ->
          other
      end

    call(name, args, p, e)
  end

  defp item(%{"type" => "custom_tool_call", "name" => name} = p, e),
    do: call(name, %{"input" => p["input"]}, p, e)

  defp item(%{"type" => "web_search_call", "action" => %{"query" => q}} = p, e),
    do: call("web_search", %{"query" => q}, p, e)

  defp item(%{"type" => t} = p, e)
       when t in ["function_call_output", "custom_tool_call_output"] do
    out = text(p["output"])

    message(
      %{
        "role" => "toolResult",
        "toolName" => if(shell_output?(out), do: "bash"),
        "isError" => error_output?(p),
        "content" => out
      },
      e
    )
  end

  defp item(_p, _e), do: nil

  defp call(name, args, p, e),
    do:
      message(
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "toolCall", "id" => p["call_id"], "name" => name, "arguments" => args}
          ]
        },
        e
      )

  defp message(m, e),
    do: %{"type" => "message", "id" => get_in(e, ["payload", "id"]), "message" => m}

  defp command(c) when is_list(c), do: Enum.join(c, " ")
  defp command(c), do: to_string(c)

  defp injected?(text),
    do: Enum.any?(@injected, &String.starts_with?(String.trim_leading(text), &1))

  # exec_command output starts with a header ("Chunk ID", "Wall time", "Process exited with code").
  defp shell_output?(out), do: Regex.match?(~r/^(Chunk ID:|Exit code:|Wall time:)/, out)

  defp error_output?(%{"type" => t, "output" => out})
       when t in ["function_call_output", "custom_tool_call_output"] do
    case Regex.run(~r/(?:Process exited with code|Exit code:) (\d+)/, text(out)) do
      [_, code] -> code != "0"
      _ -> false
    end
  end

  defp error_output?(_), do: false

  # Text of Codex content: a string, or blocks of input/output/summary text.
  defp text(c) when is_binary(c), do: c

  defp text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"text" => t} when is_binary(t) -> [t]
      s when is_binary(s) -> [s]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp text(%{"content" => c}), do: text(c)
  defp text(_), do: ""
end
