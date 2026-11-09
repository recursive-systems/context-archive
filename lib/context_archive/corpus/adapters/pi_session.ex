defmodule ContextArchive.Corpus.Adapters.PiSession do
  @moduledoc """
  Adapter for Pi coding-agent session files (source kind `pi-sessions`).

  File layout under `~/.pi/agent/sessions` (paths are relative to that root):

    * `<project-dir>/<timestamp>_<session-uuid>.jsonl` - a top-level session; the
      header's `parentSession` names the session it was forked or cloned from
    * `<project-dir>/<parent-stem>/<run-id>/run-<n>/session.jsonl` - a pi-subagents
      child session; its parent is the session whose file stem is `<parent-stem>`
    * `<project-dir>/subagent-artifacts/*` - pi-subagents' own transcript format;
      archived raw, not parsed (it duplicates the child sessions)

  The first line of every session file is its header (`"type":"session"`).

  Adapter interface (used by `Corpus.Ingestor`, shared with the Claude Code and Codex
  adapters): `session_path?/1`, `document_info/2` (from the decoded first lines and the
  path), `header?/1` (a line that is the document, not a record), `record_info/1`,
  `to_pi/1` (the entry the `Chunker` reads, or nil), `title/1`, `record_kind/0`.
  """

  @record_kind "pi-entry"
  @document_kind "pi-session"

  def record_kind, do: @record_kind
  def document_kind, do: @document_kind

  @doc "Whether a stream path is a parseable Pi session file."
  def session_path?(path) do
    String.ends_with?(path, ".jsonl") and "subagent-artifacts" not in Path.split(path)
  end

  @doc "Document attributes from the file's first lines (its header) and path."
  def document_info([], _path), do: {:error, :no_header_yet}
  def document_info([header | _], path), do: header_info(header, path)

  @doc "Whether an entry is the session header (the document, not a record)."
  def header?(%{"type" => "session"}), do: true
  def header?(_), do: false

  @doc "Pi entries are what the Chunker reads already."
  def to_pi(entry), do: entry

  defp header_info(%{"type" => "session", "id" => id} = header, path) do
    {parent, meta} = lineage(header, Path.split(path))

    {:ok,
     %{
       kind: @document_kind,
       external_id: id,
       project: header["cwd"],
       parent_external_id: parent,
       started_at: parse_time(header["timestamp"]),
       metadata: Map.merge(meta, %{"path" => path, "version" => header["version"]})
     }}
  end

  defp header_info(_header, _path), do: {:error, :not_a_session_header}

  defp lineage(_header, [_project, parent_stem, run_id, "run-" <> n, "session.jsonl"]) do
    {session_uuid(parent_stem),
     %{
       "subagent_run_id" => run_id,
       "subagent_run_index" => parse_int(n),
       "subagent_child" => true
     }}
  end

  defp lineage(header, _parts) do
    case header["parentSession"] do
      p when is_binary(p) ->
        {session_uuid(Path.basename(p, ".jsonl")), %{"forked_from_path" => p}}

      _ ->
        {nil, %{}}
    end
  end

  # "2026-09-10T20-59-33-687Z_01a08d1e-61b7-7114-9457-bf2c64754169" -> the UUID part.
  defp session_uuid(stem) do
    case String.split(stem, "_") |> List.last() do
      uuid when byte_size(uuid) == 36 -> uuid
      _ -> nil
    end
  end

  @doc "Record attributes for one decoded entry (not the header)."
  def record_info(entry) do
    message = if entry["type"] == "message", do: entry["message"] || %{}, else: %{}

    %{
      kind: @record_kind,
      external_id: entry["id"],
      parent_external_id: entry["parentId"],
      entry_type: entry["type"],
      role: message["role"],
      tool_name: message["toolName"],
      is_error: message["isError"] == true or message["stopReason"] == "error",
      occurred_at: parse_time(entry["timestamp"])
    }
  end

  @doc "Session title if this entry names the session."
  def title(%{"type" => "session_info", "name" => name}) when is_binary(name) and name != "",
    do: name

  def title(_), do: nil

  def parse_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  def parse_time(_), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
