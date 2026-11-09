defmodule ContextArchive.E2E.CorpusTest do
  @moduledoc """
  Pi sessions from a machine's session directory, sent by the real shipper, parsed on
  the server's real Oban queues, and read back through the read API. The few things
  the API does not show (a chunk's embed? flag, how many record rows are shared
  between forks) are read from the test database.
  """
  use ContextArchive.E2ECase, async: false

  alias ContextArchive.{Corpus, Ingest}

  @moduletag :shipper

  @parent_id "01a08d1e-61b7-7114-9457-bf2c64754169"
  @long_output String.duplicate("line of output\n", 200)

  setup do
    ingest = mint!("mini-ingest", "ingest", source: "mini")

    {:ok,
     mini: machine!("mini", ingest),
     admin: mint!("admin", "admin"),
     reader: mint!("reader", "read", scopes: "agents")}
  end

  defp entries(session_id) do
    [
      %{
        type: "session",
        version: 3,
        id: session_id,
        timestamp: "2026-09-20T10:00:00.000Z",
        cwd: "/home/debian/project"
      },
      %{
        type: "message",
        id: "a0000001",
        parentId: nil,
        timestamp: "2026-09-20T10:00:01.000Z",
        message: %{
          role: "user",
          content: "Why does the deploy script fail on build-02?",
          timestamp: 1
        }
      },
      %{
        type: "message",
        id: "a0000002",
        parentId: "a0000001",
        timestamp: "2026-09-20T10:00:02.000Z",
        message: %{
          role: "assistant",
          model: "m",
          stopReason: "toolUse",
          content: [
            %{type: "thinking", thinking: "Check the logs first."},
            %{type: "text", text: "Let me look at the logs."},
            %{
              type: "toolCall",
              id: "c1",
              name: "bash",
              arguments: %{command: "journalctl -u deploy -n 50"}
            }
          ]
        }
      },
      %{
        type: "message",
        id: "a0000003",
        parentId: "a0000002",
        timestamp: "2026-09-20T10:00:03.000Z",
        message: %{
          role: "toolResult",
          toolCallId: "c1",
          toolName: "bash",
          isError: false,
          content: [%{type: "text", text: @long_output}]
        }
      },
      %{
        type: "message",
        id: "a0000004",
        parentId: "a0000003",
        timestamp: "2026-09-20T10:00:04.000Z",
        message: %{
          role: "toolResult",
          toolCallId: "c2",
          toolName: "read",
          isError: true,
          content: [%{type: "text", text: "ENOENT: no such file /etc/deploy.conf"}]
        }
      },
      %{
        type: "compaction",
        id: "a0000005",
        parentId: "a0000004",
        timestamp: "2026-09-20T10:00:05.000Z",
        summary: "Investigated deploy failure; config file missing.",
        firstKeptEntryId: "a0000004",
        tokensBefore: 1000
      },
      %{
        type: "session_info",
        id: "a0000006",
        parentId: "a0000005",
        timestamp: "2026-09-20T10:00:06.000Z",
        name: "Deploy failure"
      }
    ]
  end

  defp parent_path, do: "--home-debian-project--/2026-09-20T10-00-00-000Z_#{@parent_id}.jsonl"

  defp document!(token, id) do
    assert {200, doc} = get(token, "/api/v1/documents/#{id}", limit: 200)
    doc
  end

  # Every chunk of a session, as the server stored it (embed? is not in the API).
  defp chunks(session_id) do
    Corpus.list_chunks!(authorize?: false)
    |> Enum.filter(&(&1.metadata["session_id"] == session_id))
  end

  # {records, chunks, document memberships} in the test database.
  defp counts do
    {length(Corpus.list_records!(authorize?: false)),
     length(Corpus.list_chunks!(authorize?: false)),
     length(Ash.read!(Corpus.DocumentRecord, authorize?: false))}
  end

  test "a session becomes a document, records and policy-shaped chunks", ctx do
    write_file!(ctx.mini, parent_path(), jsonl(entries(@parent_id)))
    ship!(ctx.mini)
    parse_now!(ctx.admin)

    doc = document!(ctx.reader, @parent_id)
    d = doc["document"]
    assert d["session_id"] == @parent_id
    assert d["title"] == "Deploy failure"
    assert d["project"] == "/home/debian/project"
    assert d["machine"] == "mini" and d["scope"] == "agents"
    # Stored and returned in UTC, without an offset.
    assert NaiveDateTime.from_iso8601!(d["last_record_at"]) == ~N[2026-09-20 10:00:06.000000]

    # Six entries after the header, in file order.
    assert Enum.map(doc["records"], & &1["entry_id"]) ==
             ~w(a0000001 a0000002 a0000003 a0000004 a0000005 a0000006)

    assert length(Corpus.list_records!(authorize?: false)) == 6

    by_kind = @parent_id |> chunks() |> Enum.group_by(& &1.kind)

    assert [%{text: "Why does the deploy script fail on build-02?", embed?: true}] =
             by_kind[:user]

    assert [%{text: "Check the logs first.", embed?: true}] = by_kind[:thinking]
    assert [%{text: "Let me look at the logs.", embed?: true}] = by_kind[:assistant]

    assert Enum.any?(
             by_kind[:tool_call],
             &(&1.embed? and &1.text == "bash: journalctl -u deploy -n 50")
           )

    assert [%{text: "ENOENT: no such file /etc/deploy.conf", embed?: true}] = by_kind[:tool_error]
    assert [%{embed?: true}] = by_kind[:summary]

    # Long bash output: an embedded head+tail digest plus the full text, keyword-only.
    [digest, full] = Enum.sort_by(by_kind[:tool_output], & &1.part)
    assert digest.embed? and String.contains?(digest.text, "…")
    refute full.embed?
    assert full.text == @long_output

    # The same, as a reader finds it: the error by keyword, with its kind and record.
    [hit] = search!(ctx.reader, %{query: "ENOENT", mode: "keyword"})
    assert hit["kind"] == "tool_error"
    assert hit["record"]["entry_id"] == "a0000004" and hit["record"]["is_error"]
    assert hit["document"]["title"] == "Deploy failure"

    # The status counts what is waiting for a vector: every embed? chunk.
    {200, status} = get(ctx.admin, "/api/v1/status")
    assert status["documents"] == 1
    assert status["chunks"] == length(chunks(@parent_id))

    assert status["embedding"]["embeddable_chunks"] ==
             Enum.count(chunks(@parent_id), & &1.embed?)
  end

  test "parsing again changes nothing", ctx do
    write_file!(
      ctx.mini,
      "p/2026-09-20T10-00-00-000Z_#{@parent_id}.jsonl",
      jsonl(entries(@parent_id))
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)
    before = counts()

    # What the operator does to re-parse a stream: move its parse mark back to 0
    # (with the queues held, so the per-minute cron cannot parse before we look).
    ContextArchive.DataCase.quiet_oban(fn ->
      [stream] = Ingest.list_streams!(authorize?: false)
      Ingest.mark_stream_parsed!(stream, 0, authorize?: false)
      {200, status} = get(ctx.admin, "/api/v1/status")
      assert [%{"unparsed_bytes" => n}] = status["sources"]
      assert n == stream.bytes_received
    end)

    parse_now!(ctx.admin)
    assert counts() == before
  end

  test "a forked session shares the copied entries instead of duplicating them", ctx do
    fork_id = "01a0aaaa-0000-7000-8000-000000000001"

    write_file!(
      ctx.mini,
      "p/2026-09-20T10-00-00-000Z_#{@parent_id}.jsonl",
      jsonl(entries(@parent_id))
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)

    [_header | copied] = entries(@parent_id)

    fork_header = %{
      type: "session",
      version: 3,
      id: fork_id,
      timestamp: "2026-09-21T09:00:00.000Z",
      cwd: "/home/debian/project",
      parentSession:
        "/home/debian/.pi/agent/sessions/p/2026-09-20T10-00-00-000Z_#{@parent_id}.jsonl"
    }

    extra = %{
      type: "message",
      id: "b0000001",
      parentId: "a0000006",
      timestamp: "2026-09-21T09:00:01.000Z",
      message: %{role: "user", content: "Continue in the fork", timestamp: 2}
    }

    write_file!(
      ctx.mini,
      "p/2026-09-21T09-00-00-000Z_#{fork_id}.jsonl",
      jsonl([fork_header | copied] ++ [extra])
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)

    fork = document!(ctx.reader, fork_id)
    assert fork["document"]["parent_session_id"] == @parent_id
    assert length(fork["records"]) == 7
    assert List.last(fork["records"])["entry_id"] == "b0000001"

    # Seven record rows in all, each copied one shared by both sessions: 6 + 7 memberships.
    {records, _chunks, memberships} = counts()
    assert {records, memberships} == {7, 13}
  end

  test "a subagent's child session links to its parent through its path", ctx do
    child_id = "01a0bbbb-0000-7000-8000-000000000002"

    header = %{
      type: "session",
      version: 3,
      id: child_id,
      timestamp: "2026-09-20T11:00:00.000Z",
      cwd: "/home/debian/project"
    }

    write_file!(
      ctx.mini,
      "p/2026-09-20T10-00-00-000Z_#{@parent_id}/run-uuid-1/run-0/session.jsonl",
      jsonl([header])
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)

    d = document!(ctx.reader, child_id)["document"]
    assert d["parent_session_id"] == @parent_id
    assert d["subagent_run_id"] == "run-uuid-1"

    [doc] = Corpus.list_documents!(authorize?: false)
    assert doc.metadata["subagent_run_index"] == 0
  end

  test "subagent-artifacts transcripts are archived but not parsed", ctx do
    write_file!(
      ctx.mini,
      "p/subagent-artifacts/x_worker_transcript.jsonl",
      ~s({"recordType":"x"}\n)
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)

    assert archived("mini", "p/subagent-artifacts/x_worker_transcript.jsonl") ==
             ~s({"recordType":"x"}\n)

    {200, status} = get(ctx.admin, "/api/v1/status")
    assert status["documents"] == 0 and status["chunks"] == 0
    assert [%{"files" => 1, "unparsed_bytes" => 0}] = status["sources"]
  end

  test "NUL is stored as U+FFFD in the database; the raw archive keeps it", ctx do
    session = "01a0cccc-0000-7000-8000-000000000003"

    header = %{
      type: "session",
      version: 3,
      id: session,
      timestamp: "2026-09-20T12:00:00.000Z",
      cwd: "/x"
    }

    msg = %{
      type: "message",
      id: "n1",
      parentId: nil,
      timestamp: "2026-09-20T12:00:01.000Z",
      message: %{
        role: "toolResult",
        toolName: "bash",
        isError: true,
        content: [%{type: "text", text: "bad\u0000byte"}]
      }
    }

    write_file!(ctx.mini, "p/2026-09-20T12-00-00-000Z_x.jsonl", jsonl([header, msg]))
    ship!(ctx.mini)
    parse_now!(ctx.admin)

    assert [hit] = search!(ctx.admin, %{query: "bad", mode: "keyword", unmasked: true})
    assert hit["text"] == "bad\uFFFDbyte"
    assert [%{text: "bad\uFFFDbyte"}] = Corpus.list_chunks!(authorize?: false)
    assert archived("mini", "p/2026-09-20T12-00-00-000Z_x.jsonl") =~ "bad\\u0000byte"
  end

  test "long text is split into overlapping parts that fit the embedding window; blank text is not a chunk",
       ctx do
    session = "01a0dddd-0000-7000-8000-00000000000a"
    long = String.slice(String.duplicate("lorem ipsum ", 200), 0, 1999) <> "z"
    assert String.length(long) == 2000

    write_file!(
      ctx.mini,
      "p/2026-09-20T13-00-00-000Z_#{session}.jsonl",
      jsonl([
        %{
          type: "session",
          version: 3,
          id: session,
          timestamp: "2026-09-20T13:00:00.000Z",
          cwd: "/x"
        },
        %{
          type: "message",
          id: "l1",
          parentId: nil,
          timestamp: "2026-09-20T13:00:01.000Z",
          message: %{role: "user", content: long}
        },
        %{
          type: "message",
          id: "l2",
          parentId: "l1",
          timestamp: "2026-09-20T13:00:02.000Z",
          message: %{role: "user", content: "   "}
        }
      ])
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)

    parts =
      search!(ctx.reader, %{
        query: "lorem",
        mode: "keyword",
        kinds: ["user"],
        limit: 100,
        dedupe: false
      })
      |> Enum.sort_by(& &1["part"])
      |> Enum.map(& &1["text"])

    assert length(parts) == 3
    assert Enum.all?(parts, &(String.length(&1) <= 900))
    # Each part starts with the last 100 characters of the one before.
    for [a, b] <- Enum.chunk_every(parts, 2, 1, :discard) do
      assert String.starts_with?(b, String.slice(a, -100, 100))
    end

    assert Enum.join([hd(parts) | Enum.map(tl(parts), &String.slice(&1, 100..-1//1))]) == long

    # The blank message is a record with no searchable text.
    doc = document!(ctx.reader, session)
    assert [%{"entry_id" => "l1"}, %{"entry_id" => "l2", "text" => ""}] = doc["records"]
  end
end
