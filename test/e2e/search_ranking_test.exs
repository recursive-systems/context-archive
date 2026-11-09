defmodule ContextArchive.E2E.SearchRankingTest do
  @moduledoc """
  What search does after fusing its rankings, over real HTTP on sessions the real
  shipper sent: near-duplicate passages collapse into one, one session can't fill the
  results, and a caller can leave out its own session and the runs that copied it.
  """
  use ContextArchive.E2ECase, async: false

  @moduletag :shipper

  @busy "01a0b001-0000-7000-8000-000000000001"
  @copies ["01a0b002-0000-7000-8000-000000000002", "01a0b003-0000-7000-8000-000000000003"]
  @notice "01a0b004-0000-7000-8000-000000000004"
  @mine "01a0b005-0000-7000-8000-000000000005"
  @my_fork "01a0b006-0000-7000-8000-000000000006"
  @other "01a0b007-0000-7000-8000-000000000007"
  @tools "01a0b008-0000-7000-8000-000000000008"

  # A skill file read in several worktrees, then quoted under a notice's header.
  @skill """
  Intent and boundaries for a client box: an exe.dev VM that runs maintenance agents
  for one client. Never deploy from it without the owner's approval, keep its tailnet
  tag client-only, and report every change to the client channel.
  """

  setup do
    admin = mint!("admin", "admin")
    mini = machine!("mini", mint!("mini-ingest", "ingest", source: "mini"))

    session!(
      mini,
      @busy,
      for(
        i <- 1..5,
        do: "kestrel step #{i}: #{Enum.at(~w(build test lint package upload), i - 1)} finished"
      )
    )

    for id <- @copies, do: session!(mini, id, ["Reading the skill: " <> @skill])
    session!(mini, @notice, ["[loop client-check · run #1 · done] " <> @skill])

    session!(mini, @mine, ["We decided the osprey migration waits for Friday."])

    session!(
      mini,
      @my_fork,
      ["We decided the osprey migration waits for Friday.", "osprey fork run notes"],
      parent: @mine
    )

    session!(mini, @other, ["Last month the osprey migration was blocked on backups."])

    # One tool call is indexed twice: its one-line summary and its arguments as JSON.
    command = "cat >> heron-journal.md <<'EOF'\n## heron pass\nfreed 12 GB\nEOF"

    write_file!(
      mini,
      "p/2026-09-20T10-00-00-000Z_#{@tools}.jsonl",
      jsonl([
        %{
          type: "session",
          version: 3,
          id: @tools,
          timestamp: "2026-09-20T10:00:00.000Z",
          cwd: "/p"
        },
        %{
          type: "message",
          id: "t1",
          parentId: nil,
          timestamp: "2026-09-20T10:00:01.000Z",
          message: %{
            role: "assistant",
            content: [%{type: "toolCall", id: "c1", name: "bash", arguments: %{command: command}}]
          }
        }
      ])
    )

    ship!(mini)
    parse_now!(admin)
    {:ok, reader: mint!("agents-reader", "read", scopes: "agents")}
  end

  defp session!(machine, id, texts, opts \\ []) do
    header =
      %{type: "session", version: 3, id: id, timestamp: "2026-09-20T10:00:00.000Z", cwd: "/p"}
      |> then(fn h ->
        if p = opts[:parent],
          do:
            Map.put(
              h,
              :parentSession,
              "/home/debian/.pi/agent/sessions/p/2026-09-20T10-00-00-000Z_#{p}.jsonl"
            ),
          else: h
      end)

    messages =
      texts
      |> Enum.with_index(1)
      |> Enum.map(fn {text, i} ->
        %{
          type: "message",
          id: "#{String.slice(id, 4, 4)}#{i}",
          parentId: nil,
          timestamp: "2026-09-20T10:00:0#{i}.000Z",
          message: %{role: "user", content: text}
        }
      end)

    write_file!(machine, "p/2026-09-20T10-00-00-000Z_#{id}.jsonl", jsonl([header | messages]))
  end

  defp sessions(results), do: Enum.map(results, & &1["document"]["session_id"])

  test "at most three passages come from one session unless asked otherwise", %{reader: r} do
    assert length(search!(r, %{query: "kestrel", mode: "keyword"})) == 3
    assert length(search!(r, %{query: "kestrel", mode: "keyword", per_session: 10})) == 5
    # Naming the session means reading it: no cap.
    assert length(search!(r, %{query: "kestrel", mode: "keyword", session_ids: [@busy]})) == 5
  end

  test "the same passage read in several places comes back once, counting the rest", %{reader: r} do
    [hit] = search!(r, %{query: "client box maintenance", mode: "keyword"})
    assert hit["duplicates"] == 2
    assert hit["text"] =~ "Intent and boundaries"

    all = search!(r, %{query: "client box maintenance", mode: "keyword", dedupe: false})
    assert Enum.sort(sessions(all)) == Enum.sort([@notice | @copies])
    assert Enum.all?(all, &(&1["duplicates"] == 0))
  end

  test "two chunks of one record come back as one", %{reader: r} do
    both = search!(r, %{query: "heron", mode: "keyword", dedupe: false})
    assert length(both) == 2
    assert Enum.uniq_by(both, & &1["record"]["id"]) |> length() == 1

    [hit] = search!(r, %{query: "heron", mode: "keyword"})
    assert hit["duplicates"] == 1
  end

  test "a caller can leave out its own session and the runs copied from it", %{reader: r} do
    everyone = sessions(search!(r, %{query: "osprey migration", mode: "keyword", dedupe: false}))
    assert @mine in everyone and @my_fork in everyone

    assert sessions(search!(r, %{query: "osprey", mode: "keyword", exclude_session_ids: [@mine]})) ==
             [@other]
  end
end
