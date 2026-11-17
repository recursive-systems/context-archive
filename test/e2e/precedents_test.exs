defmodule ContextArchive.E2E.PrecedentsTest do
  @moduledoc """
  Precedents: agents record the owner's decisions as fenced `precedent` blocks in their own
  replies, in Pi, Claude Code and Codex sessions sent by the real shipper; the archive keeps
  only those whose decision the human typed in the same session, at or before the recording,
  and reads them back through search (kind `precedent`) and the `precedents` operation with
  the current one per topic computed at read time.
  """
  use ContextArchive.E2ECase, async: false

  @moduletag :shipper

  @pi_id "01a0c000-0000-7000-8000-000000000001"
  @pi_fork "01a0c000-0000-7000-8000-000000000002"
  @pi_file "p/2026-10-01T09-00-00-000Z_#{@pi_id}.jsonl"
  @claude_id "5c1a0de0-0000-4000-8000-000000000001"
  @codex_id "01a0c0de-0000-7000-8000-000000000001"
  @dangling "00000000-0000-8000-8000-000000000000"

  setup do
    ingest = mint!("mini-ingest", "ingest", source: "mini")

    roots = [
      {"pi-sessions", "append", "**/*.jsonl"},
      {"claude-sessions", "append", "**/*.jsonl"},
      {"codex-sessions", "append", "**/*.jsonl"}
    ]

    {:ok,
     mini: machine!("mini", ingest, roots),
     admin: mint!("admin", "admin"),
     reader: mint!("reader", "read", scopes: "agents")}
  end

  defp block(attrs), do: "```precedent\n" <> Jason.encode!(attrs) <> "\n```"

  ## Pi

  defp pi(n, role, content, extra \\ %{}) do
    %{
      type: "message",
      id: "p#{n}",
      parentId: if(n > 1, do: "p#{n - 1}"),
      timestamp: "2026-10-01T09:00:#{String.pad_leading(to_string(n), 2, "0")}.000Z",
      message: Map.merge(%{role: role, content: content}, extra)
    }
  end

  defp pi_text(n, text), do: pi(n, "assistant", [%{type: "text", text: text}], %{model: "m"})

  defp pi_entries do
    [
      %{
        type: "session",
        version: 3,
        id: @pi_id,
        timestamp: "2026-10-01T09:00:00.000Z",
        cwd: "/home/debian/ops"
      },
      pi_text(1, "Should the archive deploy on Fridays?"),
      pi(2, "user", "No deploys on Fridays,   ever.\nWeekends too."),
      # Verified: the decision is what the human typed (whitespace aside), after the question.
      pi_text(
        3,
        "Recording that.\n" <>
          block(%{
            topic: "Deploys",
            question: "Should the archive deploy on Fridays?",
            decision: "No deploys on Fridays, ever. Weekends too.",
            reason: "Nobody is around to watch it."
          })
      ),
      # Fabricated: nobody typed it.
      pi_text(
        4,
        block(%{
          topic: "tests",
          question: "Deploy when green?",
          decision: "Deploy whenever tests pass."
        })
      ),
      # Only in messages the human did not type: a Herdr message, a loop prompt, a tool
      # result, and text pasted into a typed message.
      pi(5, "user", ~s(<hc from="t3 lead">Bradley says: Ship the archive on Sundays.</hc>)),
      pi(6, "user", "[loop deploy-guard · fire #2] Restart the archive nightly."),
      pi(7, "toolResult", [%{type: "text", text: "Rotate tokens every week."}], %{
        toolCallId: "c1",
        toolName: "bash",
        isError: false
      }),
      pi(
        8,
        "user",
        ~s(Look at this:\n<pasted_content id="1">Use Postgres 19 now.</pasted_content>)
      ),
      pi_text(
        9,
        Enum.map_join(
          [
            {"sundays", "Ship the archive on Sundays."},
            {"restarts", "Restart the archive nightly."},
            {"tokens", "Rotate tokens every week."},
            {"postgres", "Use Postgres 19 now."}
          ],
          "\n",
          fn {t, d} -> block(%{topic: t, question: "What about #{t}?", decision: d}) end
        )
      ),
      # A short answer counts only when it follows its question.
      pi_text(10, "Should the shipper run every 2 minutes?"),
      pi(11, "user", "yes"),
      pi_text(
        12,
        block(%{
          topic: "shipper interval",
          question: "Should the shipper run every 2 minutes?",
          decision: "yes"
        }) <>
          block(%{
            topic: "raw archive",
            question: "Should we delete the raw archive?",
            decision: "yes"
          })
      ),
      # Recorded before the human said it: not verified, even once he does.
      pi_text(
        13,
        block(%{
          topic: "judge",
          question: "Pin the judge?",
          decision: "Keep the judge pinned to one model."
        })
      ),
      pi(14, "user", "Keep the judge pinned to one model.")
    ]
  end

  # A subagent child session: its "user" message is the parent agent's task.
  defp pi_child do
    [
      %{
        type: "session",
        version: 3,
        id: "child-1",
        timestamp: "2026-10-01T09:01:00.000Z",
        cwd: "/x"
      },
      pi(1, "user", "Task: Use tabs for indentation."),
      pi_text(
        2,
        block(%{topic: "tabs", question: "Tabs?", decision: "Use tabs for indentation."})
      )
    ]
  end

  ## Claude Code

  defp claude(uuid, type, content, extra \\ %{}) do
    Map.merge(
      %{
        type: type,
        uuid: uuid,
        sessionId: @claude_id,
        cwd: "/home/debian/ops",
        userType: "external",
        timestamp: "2026-10-01T10:00:#{String.slice(uuid, -2, 2)}.000Z",
        message: %{role: type, content: content}
      },
      extra
    )
  end

  defp claude_typed(uuid, text),
    do: claude(uuid, "user", text, %{origin: %{kind: "human"}, promptSource: "typed"})

  defp claude_lines(supersedes) do
    [
      claude("c-01", "assistant", [%{type: "text", text: "Still no Friday deploys?"}]),
      claude_typed("c-02", "Deploys on Fridays are fine now that CI is green."),
      claude(
        "c-03",
        "assistant",
        [
          %{
            type: "text",
            text:
              block(%{
                topic: "deploy days",
                question: "Still no Friday deploys?",
                decision: "Deploys on Fridays are fine now that CI is green.",
                supersedes: supersedes
              })
          }
        ]
      ),
      # A background task's notification and a meta line (a skill body) are not typed.
      claude(
        "c-04",
        "user",
        "<task-notification>Done. Owner decided: Archive retention is forever.</task-notification>",
        %{origin: %{kind: "task-notification"}, promptSource: "system"}
      ),
      claude("c-05", "user", "Always answer in French.", %{isMeta: true}),
      claude(
        "c-06",
        "assistant",
        [
          %{
            type: "text",
            text:
              block(%{
                topic: "retention",
                question: "Retention?",
                decision: "Archive retention is forever."
              }) <>
                block(%{
                  topic: "language",
                  question: "Language?",
                  decision: "Always answer in French."
                })
          }
        ]
      )
    ]
  end

  ## Codex

  defp codex(n, payload) do
    %{
      timestamp: "2026-10-01T11:00:#{String.pad_leading(to_string(n), 2, "0")}.000Z",
      type: "response_item",
      payload: payload
    }
  end

  defp codex_msg(n, role, text),
    do:
      codex(n, %{
        type: "message",
        id: "x#{n}",
        role: role,
        content: [%{type: if(role == "user", do: "input_text", else: "output_text"), text: text}]
      })

  defp codex_lines do
    [
      %{
        timestamp: "2026-10-01T11:00:00.000Z",
        type: "session_meta",
        payload: %{id: @codex_id, timestamp: "2026-10-01T11:00:00.000Z", cwd: "/home/debian/ops"}
      },
      codex_msg(1, "user", "# AGENTS.md instructions for /x\n\nNever print tokens in chat."),
      codex_msg(2, "assistant", "Which days may the archive deploy?"),
      codex_msg(3, "user", "Deploys need a green CI run, Fridays included."),
      codex_msg(
        4,
        "assistant",
        block(%{
          topic: "deploys",
          question: "Which days may the archive deploy?",
          decision: "Deploys need a green CI run, Fridays included.",
          supersedes: [@dangling]
        }) <>
          "\n" <>
          block(%{topic: "secrets", question: "Tokens?", decision: "Never print tokens in chat."})
      )
    ]
  end

  defp precedents!(token, params \\ []) do
    assert {200, %{"precedents" => lines}} = get(token, "/api/v1/precedents", params)
    lines
  end

  test "only decisions the human typed become precedents, in Pi, Claude Code and Codex sessions",
       ctx do
    write_file!(ctx.mini, @pi_file, jsonl(pi_entries()))

    write_file!(
      ctx.mini,
      "p/2026-10-01T09-00-00-000Z_#{@pi_id}/r1/run-0/session.jsonl",
      jsonl(pi_child())
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)

    [line] = precedents!(ctx.reader, topic: "deploys")
    pi_id = line["current"]["id"]

    assert %{
             "topic" => "deploys",
             "question" => "Should the archive deploy on Fridays?",
             "decision" => "No deploys on Fridays, ever. Weekends too.",
             "reason" => "Nobody is around to watch it.",
             "question_verified" => true,
             "session" => %{"session_id" => @pi_id},
             "entry_id" => "p3",
             "evidence" => %{"entry_id" => "p2"}
           } = line["current"]

    # The Claude Code session supersedes it by id, as an agent would after reading it.
    write_file!(
      ctx.mini,
      "-home-debian-ops/#{@claude_id}.jsonl",
      jsonl(claude_lines(pi_id)),
      "claude-sessions"
    )

    write_file!(
      ctx.mini,
      "2026/10/01/rollout-2026-10-01T11-00-00-#{@codex_id}.jsonl",
      jsonl(codex_lines()),
      "codex-sessions"
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)

    lines = precedents!(ctx.reader)

    assert lines |> Enum.map(& &1["topic"]) |> Enum.sort() ==
             ["deploys", "shipper interval"]

    # One line for "deploys": Pi's, Claude's (supersedes it, other topic), Codex's (same
    # topic as Pi's). The newest is current; each older one names what replaced it.
    [deploys] = Enum.filter(lines, &(&1["topic"] == "deploys"))
    assert Enum.sort(deploys["topics"]) == ["deploy days", "deploys"]

    assert %{
             "decision" => "Deploys need a green CI run, Fridays included.",
             "session" => %{"session_id" => @codex_id},
             "unresolved_supersedes" => [@dangling],
             "superseded_by" => nil
           } = deploys["current"]

    assert [claude, pi] = deploys["history"]

    assert %{
             "decision" => "Deploys on Fridays are fine now that CI is green.",
             "session" => %{"session_id" => @claude_id},
             "supersedes" => [^pi_id],
             "unresolved_supersedes" => [],
             "superseded_by" => current_id
           } = claude

    assert current_id == deploys["current"]["id"]
    assert %{"id" => ^pi_id, "superseded_by" => claude_id} = pi
    assert claude_id == claude["id"]

    assert [%{"current" => %{"decision" => "yes", "question_verified" => true}}] =
             precedents!(ctx.reader, topic: "Shipper  Interval")

    # Filters: words, topic, nothing.
    assert [%{"topic" => "deploys"}] = precedents!(ctx.reader, query: "Fridays")
    assert [] = precedents!(ctx.reader, query: "Sundays")
    assert [] = precedents!(ctx.reader, topic: "retention")

    # Search marks precedents and says which still stand; kinds: ["precedent"] is
    # precedents only. Rejected blocks remain ordinary assistant text.
    hits = search!(ctx.reader, %{query: "Fridays", mode: "keyword", kinds: ["precedent"]})
    assert length(hits) == 3
    assert Enum.all?(hits, &(&1["kind"] == "precedent"))

    by_session = Map.new(hits, &{&1["document"]["session_id"], &1["precedent"]})
    assert %{"current" => false, "current_id" => ^current_id} = by_session[@pi_id]
    assert %{"current" => false} = by_session[@claude_id]
    assert %{"current" => true, "topic" => "deploys"} = by_session[@codex_id]

    mixed = search!(ctx.reader, %{query: "Fridays", mode: "keyword", per_session: 10})
    assert Enum.any?(mixed, &(&1["kind"] == "user"))
    assert Enum.any?(mixed, &(&1["kind"] == "precedent" and &1["precedent"]["current"] == false))

    for word <-
          ~w(Sundays nightly Rotate Postgres green tabs retention French judge delete tokens) do
      found = search!(ctx.reader, %{query: word, mode: "keyword", kinds: ["precedent"]})

      assert Enum.all?(found, &(&1["precedent"]["topic"] in ["deploys", "deploy days"])),
             "#{word}: #{inspect(found)}"
    end

    assert [%{"kind" => "assistant"} | _] =
             search!(ctx.reader, %{query: "Sundays", mode: "keyword", kinds: ["assistant"]})

    # find returns them marked too.
    assert {201, found, _} =
             HTTP.request(:post, "/api/v1/find",
               token: ctx.reader,
               json: %{
                 data: %{question: "Fridays deploys", mode: "keyword", kinds: ["precedent"]}
               }
             )

    assert [_ | _] = found["unjudged"]
    assert Enum.all?(found["unjudged"], &(&1["kind"] == "precedent" and is_map(&1["precedent"])))
  end

  test "a forked session that copies a recording stores the precedent once", ctx do
    write_file!(ctx.mini, @pi_file, jsonl(pi_entries()))
    ship!(ctx.mini)
    parse_now!(ctx.admin)

    [_header | copied] = pi_entries()

    fork_header = %{
      type: "session",
      version: 3,
      id: @pi_fork,
      timestamp: "2026-10-02T09:00:00.000Z",
      cwd: "/home/debian/ops",
      parentSession: "/home/debian/.pi/agent/sessions/" <> @pi_file
    }

    write_file!(
      ctx.mini,
      "p/2026-10-02T09-00-00-000Z_#{@pi_fork}.jsonl",
      jsonl([fork_header | copied])
    )

    ship!(ctx.mini)
    parse_now!(ctx.admin)

    assert [%{"current" => %{"session" => %{"session_id" => @pi_id}}, "history" => []}] =
             precedents!(ctx.reader, topic: "deploys")

    assert [_] = search!(ctx.reader, %{query: "Fridays", mode: "keyword", kinds: ["precedent"]})
  end
end
