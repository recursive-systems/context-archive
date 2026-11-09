defmodule ContextArchive.E2E.HarnessSessionsTest do
  @moduledoc """
  Claude Code, Codex, Grok CLI and Antigravity CLI sessions, sent by the real shipper from their
  own roots (`claude-sessions`, `codex-sessions`, `grok-sessions`, `agy-sessions`), parsed on the real queues into
  the same documents, records and chunks as Pi sessions, and found through the read API.
  """
  use ContextArchive.E2ECase, async: false

  alias ContextArchive.Corpus

  @moduletag :shipper

  @claude_id "53994f21-6da3-418a-98d4-5dba8c1e917f"
  @codex_id "01a13190-c71b-7172-958b-8f83c584703b"
  @codex_parent "01a13100-0000-7000-8000-000000000001"
  @grok_id "01a13600-4381-7193-867f-7c53484ab592"
  @grok_fork "01a13601-3620-7551-a1ea-d5f6192cfae6"
  @grok_child "01a13601-1dcd-7e63-b7b3-6c82ea84a21c"
  # A working directory as Grok names its folder: URL-encoded.
  @grok_dir "%2FUsers%2Fme%2Fdev%2Fagents"
  @grok_t0 1_791_907_350_000
  @agy_id "217d326a-3646-42e3-ae48-db18d1bfbf2e"
  @agy_parent "7caf3552-e76f-4922-a21d-c04900b19db2"
  @long_output String.duplicate("line of output\n", 200)

  setup do
    ingest = mint!("mini-ingest", "ingest", source: "mini")

    roots = [
      {"claude-sessions", "append", "**/*.jsonl"},
      {"codex-sessions", "append", "**/*.jsonl"},
      {"grok-sessions", "append", "**/updates.jsonl"},
      {"agy-sessions", "append", "*.jsonl"}
    ]

    {:ok,
     mini: machine!("mini", ingest, roots),
     admin: mint!("admin", "admin"),
     reader: mint!("reader", "read", scopes: "agents")}
  end

  defp claude_lines do
    base = %{sessionId: @claude_id, cwd: "/Users/me/dev/agents", version: "2.1.296"}

    [
      %{type: "mode", mode: "normal", sessionId: @claude_id},
      Map.merge(base, %{
        type: "user",
        uuid: "c1",
        parentUuid: nil,
        timestamp: "2026-10-12T19:16:40.000Z",
        message: %{role: "user", content: "Why is the Claude deploy flaky on build-02?"}
      }),
      Map.merge(base, %{
        type: "assistant",
        uuid: "c2",
        parentUuid: "c1",
        timestamp: "2026-10-12T19:16:41.000Z",
        message: %{
          role: "assistant",
          model: "claude-sonnet-5-5",
          content: [
            %{type: "thinking", thinking: "Look at the journal first."},
            %{type: "text", text: "Checking the journal."},
            %{
              type: "tool_use",
              id: "t1",
              name: "Bash",
              input: %{command: "journalctl -u deploy"}
            },
            %{type: "tool_use", id: "t2", name: "Read", input: %{file_path: "/etc/deploy.conf"}}
          ]
        }
      }),
      Map.merge(base, %{
        type: "user",
        uuid: "c3",
        parentUuid: "c2",
        timestamp: "2026-10-12T19:16:42.000Z",
        toolUseResult: %{stdout: @long_output, stderr: ""},
        message: %{
          role: "user",
          content: [%{type: "tool_result", tool_use_id: "t1", content: @long_output}]
        }
      }),
      Map.merge(base, %{
        type: "user",
        uuid: "c4",
        parentUuid: "c3",
        timestamp: "2026-10-12T19:16:43.000Z",
        message: %{
          role: "user",
          content: [
            %{
              type: "tool_result",
              tool_use_id: "t2",
              is_error: true,
              content: [%{type: "text", text: "EACCES: permission denied /etc/deploy.conf"}]
            }
          ]
        }
      }),
      %{type: "ai-title", aiTitle: "Flaky deploy on build-02", sessionId: @claude_id}
    ]
  end

  defp codex_lines do
    [
      %{
        timestamp: "2026-10-12T19:22:14.358Z",
        type: "session_meta",
        payload: %{
          id: @codex_id,
          timestamp: "2026-10-12T19:22:14.226Z",
          cwd: "/Users/me/dev/agents/engineering",
          cli_version: "0.162.1",
          forked_from_id: @codex_parent
        }
      },
      %{
        timestamp: "2026-10-12T19:22:16.336Z",
        type: "response_item",
        payload: %{
          type: "message",
          role: "developer",
          content: [%{type: "input_text", text: "sandbox rules"}]
        }
      },
      %{
        timestamp: "2026-10-12T19:22:16.337Z",
        type: "response_item",
        payload: %{
          type: "message",
          role: "user",
          content: [%{type: "input_text", text: "# AGENTS.md instructions for /x\n\nrules"}]
        }
      },
      %{
        timestamp: "2026-10-12T19:22:16.338Z",
        type: "response_item",
        payload: %{
          type: "message",
          id: "m1",
          role: "user",
          content: [%{type: "input_text", text: "Which Codex MCP servers are failing?"}]
        }
      },
      %{
        timestamp: "2026-10-12T19:22:20.000Z",
        type: "response_item",
        payload: %{
          type: "reasoning",
          id: "r1",
          summary: [%{type: "summary_text", text: "Read the logs."}]
        }
      },
      %{
        timestamp: "2026-10-12T19:22:21.000Z",
        type: "response_item",
        payload: %{
          type: "function_call",
          name: "exec_command",
          arguments: Jason.encode!(%{cmd: "codex mcp list"}),
          call_id: "call_1"
        }
      },
      %{
        timestamp: "2026-10-12T19:22:22.000Z",
        type: "response_item",
        payload: %{
          type: "function_call_output",
          call_id: "call_1",
          output:
            "Chunk ID: 1\nProcess exited with code 1\nOutput:\ndreambeam: XNOTRESOLVED host lookup failed\n"
        }
      },
      %{
        timestamp: "2026-10-12T19:22:23.000Z",
        type: "response_item",
        payload: %{
          type: "message",
          id: "m2",
          role: "assistant",
          content: [%{type: "output_text", text: "The dreambeam server no longer resolves."}]
        }
      },
      %{
        timestamp: "2026-10-12T19:22:24.000Z",
        type: "event_msg",
        payload: %{type: "agent_message", message: "The dreambeam server no longer resolves."}
      }
    ]
  end

  # One line of a Grok session's updates.jsonl, written in `session`; `origin` is the
  # session it was first written in (a fork's copied lines still name their parent).
  defp grok(session, origin, n, update, method \\ "session/update") do
    ms = @grok_t0 + n * 1000

    %{
      timestamp: div(ms, 1000),
      method: method,
      params: %{
        sessionId: session,
        update: update,
        _meta: %{eventId: "#{origin}-#{n}", agentTimestampMs: ms}
      }
    }
  end

  defp grok_text(t), do: %{type: "text", text: t}
  defp grok_result(t), do: [%{type: "content", content: grok_text(t)}]

  defp grok_call(id, name, input, title \\ nil),
    do: %{
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: title || name,
      rawInput: input,
      _meta: %{"x.ai/tool": %{name: name}}
    }

  # Bash output as Grok keeps it: the text, the text the model saw, and the bytes.
  defp grok_bash(id, out, exit),
    do: %{
      sessionUpdate: "tool_call_update",
      toolCallId: id,
      status: "completed",
      content: grok_result(out),
      rawOutput: %{
        type: "Bash",
        output: :binary.bin_to_list(out),
        output_for_prompt: "exit: #{exit}\n" <> out,
        exit_code: exit
      }
    }

  defp grok_lines(session) do
    g = &grok(session, session, &1, &2)
    x = &grok(session, session, &1, &2, "_x.ai/session/update")

    [
      x.(1, %{sessionUpdate: "hook_execution", event_name: "session_start", runs: []}),
      g.(2, %{
        sessionUpdate: "user_message_chunk",
        content: grok_text("Why does the nightly backup hang?"),
        _meta: %{modelId: "grok-4.7", promptIndex: 0}
      }),
      g.(3, %{
        sessionUpdate: "agent_thought_chunk",
        content: grok_text("Look at the restic process first.")
      }),
      g.(4, %{sessionUpdate: "agent_message_chunk", content: grok_text("Checking the job.")}),
      g.(5, grok_call("call-a-0", "run_terminal_command", %{command: "ps -o etime -p 38931"})),
      # Grok's in-progress update repeats the call; only the first line is the call.
      g.(6, %{
        sessionUpdate: "tool_call_update",
        toolCallId: "call-a-0",
        kind: "execute",
        title: "Execute `ps -o etime -p 38931`",
        rawInput: %{variant: "Bash", command: "ps -o etime -p 38931"}
      }),
      g.(7, grok_bash("call-a-0", @long_output, 0)),
      g.(8, grok_call("call-a-1", "run_terminal_command", %{command: "ls /Volumes/Backups"})),
      g.(9, grok_bash("call-a-1", "ls: /Volumes/Backups: Operation not permitted\n", 1)),
      g.(
        10,
        grok_call("call-b-0", "use_tool", %{
          tool_name: "executor__execute",
          tool_input: %{code: "return await tools.meter.health()"}
        })
      ),
      g.(11, %{
        sessionUpdate: "tool_call_update",
        toolCallId: "call-b-0",
        status: "completed",
        rawOutput: %{
          type: "MCP",
          tool_name: "execute",
          server_name: "executor",
          output: %{OkayOutput: "meter health: backup stale since 03:15"}
        }
      }),
      g.(
        12,
        grok_call("call-c-0", "spawn_subagent", %{
          subagent_type: "general-purpose",
          description: "Read the tccd log",
          prompt: "Find pending TCC prompts."
        })
      ),
      x.(13, %{
        sessionUpdate: "subagent_spawned",
        subagent_id: @grok_child,
        parent_session_id: session,
        child_session_id: @grok_child
      }),
      g.(14, %{
        sessionUpdate: "tool_call_update",
        toolCallId: "call-c-0",
        status: "completed",
        content: grok_result("A Removable Volumes prompt for erlexec is pending."),
        rawOutput: %{
          type: "SubagentCompleted",
          output: "A Removable Volumes prompt for erlexec is pending.",
          subagent_id: @grok_child
        }
      }),
      g.(15, %{
        sessionUpdate: "agent_message_chunk",
        content: grok_text("The backup waits on a macOS permission prompt.")
      }),
      x.(16, %{
        sessionUpdate: "turn_completed",
        stop_reason: "end_turn",
        usage: %{totalTokens: 95_073, modelUsage: %{"grok-4.7-build" => %{}}}
      })
    ]
  end

  # A time from the API (UTC, with or without an offset), to the second.
  # One exported step of an agy conversation (scripts/agy-sessions), as decoded by field name.
  defp agy(idx, type, content, call \\ nil, status \\ "DONE") do
    meta = %{created_at: %{seconds: 1_791_911_853 + idx, nanos: 5_000_000}}
    meta = if call, do: Map.put(meta, :tool_call, call), else: meta

    %{
      type: "step",
      idx: idx,
      step:
        Map.merge(
          %{
            type: "CORTEX_STEP_TYPE_" <> type,
            status: "CORTEX_STEP_STATUS_" <> status,
            metadata: meta
          },
          content
        )
    }
  end

  defp agy_call(id, name, args),
    do: %{id: id, name: name, arguments_json: Jason.encode!(Map.put(args, :toolAction, "x"))}

  defp agy_result(text, args \\ []),
    do: %{generic: %{args: args, result: %{result: text, full_output_uri: "file:///x"}}}

  defp agy_lines do
    bash_ok = agy_call("c1", "run_command", %{CommandLine: "pgrep -lf restic", Cwd: "/x"})
    bash_bad = agy_call("c2", "run_command", %{CommandLine: "ls /Volumes/Backups", Cwd: "/x"})

    mcp =
      agy_call("c3", "call_mcp_tool", %{
        ServerName: "executor",
        ToolName: "execute",
        Arguments: %{code: "return 1"}
      })

    edit =
      agy_call("c4", "replace_file_content", %{
        TargetFile: "/x/notes.txt",
        TargetContent: "a",
        ReplacementContent: "b"
      })

    [
      %{
        type: "conversation",
        id: @agy_id,
        workspace: "/Users/me/dev/agents",
        parent: @agy_parent,
        agent: nil,
        nesting_depth: 1
      },
      agy(0, "USER_INPUT", %{
        user_input: %{
          user_response: "Why does the nightly backup hang?",
          items: [%{text: "Why does the nightly backup hang?"}]
        }
      }),
      agy(1, "PLANNER_RESPONSE", %{
        planner_response: %{thinking: "Check restic first.", tool_calls: [bash_ok]}
      }),
      agy(
        2,
        "GENERIC",
        agy_result("\nThe command exited with code 0.\nOutput:\n" <> @long_output),
        bash_ok
      ),
      agy(3, "PLANNER_RESPONSE", %{planner_response: %{tool_calls: [bash_bad]}}),
      agy(
        4,
        "GENERIC",
        agy_result(
          "\nThe command exited with code 1.\nOutput:\nls: /Volumes/Backups: Operation not permitted\r\n"
        ),
        bash_bad
      ),
      agy(5, "PLANNER_RESPONSE", %{planner_response: %{tool_calls: [mcp, edit]}}),
      agy(6, "GENERIC", agy_result("meter health: backup stale since 03:15"), mcp),
      agy(7, "GENERIC", agy_result("The following changes were made to /x/notes.txt."), edit),
      agy(8, "CHECKPOINT", %{checkpoint: %{"#3": 1}}),
      agy(9, "PLANNER_RESPONSE", %{
        planner_response: %{response: "The backup waits on a macOS permission prompt."}
      }),
      %{type: "title", title: "Nightly backup hang"}
    ]
  end

  defp utc(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        dt

      {:error, :missing_offset} ->
        DateTime.from_naive!(NaiveDateTime.from_iso8601!(iso), "Etc/UTC")
    end
    |> DateTime.truncate(:second)
  end

  defp chunks(session_id) do
    Corpus.list_chunks!(authorize?: false)
    |> Enum.filter(&(&1.metadata["session_id"] == session_id))
    |> Enum.group_by(& &1.kind)
  end

  test "a Claude Code session becomes a document, records and the same kinds of chunks", ctx do
    write_file!(
      ctx.mini,
      "-Users-me-dev-agents/#{@claude_id}.jsonl",
      jsonl(claude_lines()),
      "claude-sessions"
    )

    # Not a session: memory notes stay raw.
    write_file!(
      ctx.mini,
      "-Users-me-dev-agents/memory/notes.jsonl",
      jsonl([%{a: 1}]),
      "claude-sessions"
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)

    assert {200, doc} = get(ctx.reader, "/api/v1/documents/#{@claude_id}", limit: 200)
    d = doc["document"]
    assert d["session_id"] == @claude_id
    assert d["title"] == "Flaky deploy on build-02"
    assert d["project"] == "/Users/me/dev/agents"
    # Every line is a record, in file order (metadata lines included).
    assert length(doc["records"]) == 6

    by_kind = chunks(@claude_id)
    assert [%{text: "Why is the Claude deploy flaky on build-02?", embed?: true}] = by_kind[:user]
    assert [%{text: "Look at the journal first."}] = by_kind[:thinking]
    assert [%{text: "Checking the journal."}] = by_kind[:assistant]
    calls = Enum.map(by_kind[:tool_call], & &1.text)
    assert "bash: journalctl -u deploy" in calls
    assert "read: /etc/deploy.conf " in calls

    # Bash output digested like Pi's; the failed read embedded as an error.
    [digest, full] = Enum.sort_by(by_kind[:tool_output], & &1.part)
    assert digest.embed? and full.text == @long_output

    assert [%{text: "EACCES: permission denied /etc/deploy.conf", embed?: true}] =
             by_kind[:tool_error]

    [hit] = search!(ctx.reader, %{query: "EACCES", mode: "keyword"})
    assert hit["kind"] == "tool_error" and hit["record"]["is_error"]
    assert hit["document"]["title"] == "Flaky deploy on build-02"

    {200, status} = get(ctx.admin, "/api/v1/status")
    assert status["documents"] == 1
  end

  test "a Codex session becomes a document with its fork parent, without injected context",
       ctx do
    rel = "2026/10/12/rollout-2026-10-12T14-22-14-#{@codex_id}.jsonl"
    write_file!(ctx.mini, rel, jsonl(codex_lines()), "codex-sessions")
    ship!(ctx.mini)
    parse_now!(ctx.admin)

    assert {200, doc} = get(ctx.reader, "/api/v1/documents/#{@codex_id}", limit: 200)
    d = doc["document"]
    assert d["project"] == "/Users/me/dev/agents/engineering"
    assert d["parent_session_id"] == @codex_parent
    # Eight lines after the header.
    assert length(doc["records"]) == 8

    by_kind = chunks(@codex_id)
    # Developer and AGENTS.md messages are left out; what the user typed stays.
    assert [%{text: "Which Codex MCP servers are failing?"}] = by_kind[:user]
    assert [%{text: "Read the logs."}] = by_kind[:thinking]
    # The final answer once (the event_msg copy is a record only).
    assert [%{text: "The dreambeam server no longer resolves."}] = by_kind[:assistant]
    assert Enum.any?(by_kind[:tool_call], &(&1.text == "bash: codex mcp list"))
    # Non-zero exit: an embedded error.
    assert [%{embed?: true} = err] = by_kind[:tool_error]
    assert err.text =~ "XNOTRESOLVED"

    [hit] = search!(ctx.reader, %{query: "XNOTRESOLVED", mode: "keyword"})
    assert hit["document"]["session_id"] == @codex_id
  end

  test "a Grok session becomes a document and the same kinds of chunks, from text only", ctx do
    rel = "#{@grok_dir}/#{@grok_id}/updates.jsonl"
    write_file!(ctx.mini, rel, jsonl(grok_lines(@grok_id)), "grok-sessions")
    # Not a session folder: archived raw, not parsed.
    write_file!(
      ctx.mini,
      "#{@grok_dir}/not-a-session/updates.jsonl",
      jsonl([%{a: 1}]),
      "grok-sessions"
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)

    assert {200, doc} = get(ctx.reader, "/api/v1/documents/#{@grok_id}", limit: 200)
    d = doc["document"]
    assert d["session_id"] == @grok_id
    assert d["project"] == "/Users/me/dev/agents"
    assert d["parent_session_id"] == nil
    assert utc(d["started_at"]) == DateTime.from_unix!(div(@grok_t0, 1000) + 1)
    # Every line is a record, in file order, at the agent's time.
    records = doc["records"]
    assert length(records) == 16
    assert utc(hd(records)["occurred_at"]) == DateTime.from_unix!(div(@grok_t0, 1000) + 1)

    by_kind = chunks(@grok_id)
    assert [%{text: "Why does the nightly backup hang?", embed?: true}] = by_kind[:user]
    assert [%{text: "Look at the restic process first."}] = by_kind[:thinking]

    assert by_kind[:assistant] |> Enum.map(& &1.text) |> Enum.sort() ==
             ["Checking the job.", "The backup waits on a macOS permission prompt."]

    # One chunk per call (the in-progress update is a record only), named like Pi's.
    calls = by_kind[:tool_call] |> Enum.filter(& &1.embed?) |> Enum.map(& &1.text)
    assert length(calls) == 4
    assert "bash: ps -o etime -p 38931" in calls
    assert "bash: ls /Volumes/Backups" in calls
    assert "subagent: general-purpose: Read the tccd log" in calls
    assert Enum.any?(calls, &String.starts_with?(&1, "executor__execute: "))

    # Bash output digested like Pi's, from its text; MCP output through use_tool too.
    outputs = Enum.group_by(by_kind[:tool_output], & &1.metadata["tool_name"])
    [digest, full] = Enum.sort_by(outputs["bash"], & &1.part)
    assert digest.embed? and full.text == @long_output
    assert [%{text: "meter health: backup stale since 03:15", embed?: true}] = outputs["mcp"]

    # A command that exits non-zero is an embedded error.
    assert [%{text: "ls: /Volumes/Backups: Operation not permitted", embed?: true}] =
             by_kind[:tool_error]

    assert [%{text: "A Removable Volumes prompt for erlexec is pending."}] =
             by_kind[:subagent_result]

    # No chunk holds the byte-array copy of bash output.
    refute Enum.any?(List.flatten(Map.values(by_kind)), &(&1.text =~ ~r/\d+,\d+,\d+,\d+/))

    [hit] = search!(ctx.reader, %{query: "Operation not permitted", mode: "keyword"})
    assert hit["kind"] == "tool_error" and hit["record"]["is_error"]
    assert hit["document"]["session_id"] == @grok_id

    {200, status} = get(ctx.admin, "/api/v1/status")
    assert status["documents"] == 1
  end

  test "a Grok fork names its parent; its copied updates keep their times", ctx do
    # Grok copies the parent's updates into the fork, written in the fork (its session id,
    # the time of the fork) but naming the session they came from, then appends its own.
    forked_at = div(@grok_t0, 1000) + 600

    copied =
      for line <- Enum.take(grok_lines(@grok_id), 4),
          do: line |> put_in([:params, :sessionId], @grok_fork) |> Map.put(:timestamp, forked_at)

    own = [
      grok(@grok_fork, @grok_fork, 700, %{
        sessionUpdate: "user_message_chunk",
        content: grok_text("And if the drive is not mounted?")
      })
    ]

    rel = "#{@grok_dir}/#{@grok_fork}/updates.jsonl"
    write_file!(ctx.mini, rel, jsonl(copied ++ own), "grok-sessions")
    ship!(ctx.mini)
    parse_now!(ctx.admin)

    assert {200, doc} = get(ctx.reader, "/api/v1/documents/#{@grok_fork}", limit: 50)
    d = doc["document"]
    assert d["parent_session_id"] == @grok_id
    assert utc(d["started_at"]) == DateTime.from_unix!(forked_at)

    # The copied prompt keeps the time it was typed in the parent.
    prompt = Enum.find(doc["records"], &(&1["entry_type"] == "user_message_chunk"))
    assert utc(prompt["occurred_at"]) == DateTime.from_unix!(div(@grok_t0, 1000) + 2)

    assert chunks(@grok_fork)[:user] |> Enum.map(& &1.text) |> Enum.sort() ==
             ["And if the drive is not mounted?", "Why does the nightly backup hang?"]
  end

  test "an exported Antigravity CLI conversation becomes a document and the same kinds of chunks",
       ctx do
    write_file!(ctx.mini, "#{@agy_id}.jsonl", jsonl(agy_lines()), "agy-sessions")
    # Not a conversation file: archived raw, not parsed.
    write_file!(ctx.mini, "state.jsonl", jsonl([%{a: 1}]), "agy-sessions")
    ship!(ctx.mini)
    parse_now!(ctx.admin)

    assert {200, doc} = get(ctx.reader, "/api/v1/documents/#{@agy_id}", limit: 200)
    d = doc["document"]
    assert d["title"] == "Nightly backup hang"
    assert d["project"] == "/Users/me/dev/agents"
    assert d["parent_session_id"] == @agy_parent
    assert utc(d["started_at"]) == DateTime.from_unix!(1_791_911_853)
    # Every step and the title line are records; the header is the document.
    assert length(doc["records"]) == 11
    assert utc(Enum.at(doc["records"], 4)["occurred_at"]) == DateTime.from_unix!(1_791_911_857)

    by_kind = chunks(@agy_id)
    assert [%{text: "Why does the nightly backup hang?", embed?: true}] = by_kind[:user]
    assert [%{text: "Check restic first."}] = by_kind[:thinking]
    assert [%{text: "The backup waits on a macOS permission prompt."}] = by_kind[:assistant]

    calls = by_kind[:tool_call] |> Enum.filter(& &1.embed?) |> Enum.map(& &1.text)
    assert "bash: pgrep -lf restic" in calls
    assert "bash: ls /Volumes/Backups" in calls
    assert "edit: /x/notes.txt " in calls
    assert ~s(executor__execute: {"code":"return 1"}) in calls

    outputs = Enum.group_by(by_kind[:tool_output], & &1.metadata["tool_name"])
    [digest, full] = Enum.sort_by(outputs["bash"], & &1.part)
    assert digest.embed? and full.text =~ @long_output
    assert [%{text: "meter health: backup stale since 03:15", embed?: true}] = outputs["mcp"]

    # A non-zero exit is an embedded error.
    assert [%{embed?: true} = err] = by_kind[:tool_error]
    assert err.text =~ "Operation not permitted"

    [hit] = search!(ctx.reader, %{query: "Operation not permitted", mode: "keyword"})
    assert hit["kind"] == "tool_error" and hit["record"]["is_error"]
    assert hit["document"]["session_id"] == @agy_id

    {200, status} = get(ctx.admin, "/api/v1/status")
    assert status["documents"] == 1
  end
end
