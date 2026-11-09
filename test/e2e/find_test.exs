defmodule ContextArchive.E2E.FindTest do
  @moduledoc """
  `POST /api/v1/find` over real HTTP, on sessions the real shipper sent. Nothing calls out in
  tests, so TypeSafe is never asked: the judge is off (candidates come back unjudged), or on
  but pointed at a closed loopback port, with answers stored in the judgments table the way
  an earlier `find` would have left them (the test reads and writes the test database for
  what the API doesn't show, as the README allows).
  """
  use ContextArchive.E2ECase, async: false

  alias ContextArchive.{Ingest, Judge}

  @moduletag :shipper

  @deep "01a0c001-0000-7000-8000-000000000001"
  @short "01a0c002-0000-7000-8000-000000000002"
  @mine "01a0c003-0000-7000-8000-000000000003"
  @personal "01a0c004-0000-7000-8000-000000000004"

  # A long tool output whose answer sits deep inside, past what a 900-character excerpt
  # starting at the top would show.
  @long String.duplicate("routine build log line without anything of note. ", 50) <>
          "DECISION: the heron migration waits for Friday because backups are not verified. " <>
          String.duplicate("more routine build log output follows here. ", 60)

  setup do
    admin = mint!("admin", "admin")
    mini = machine!("mini", mint!("mini-ingest", "ingest", source: "mini"))
    home = machine!("home", mint!("home-ingest", "ingest", source: "home"))

    session!(mini, @deep, [tool_output("t1", @long)])
    session!(mini, @short, [user("s1", "Plover rollout notes: the canary passed on Tuesday.")])

    session!(mini, @mine, [
      user("m1", "Why does the heron migration wait? I asked this a minute ago.")
    ])

    session!(home, @personal, [
      user("p1", "Personal: the heron migration should wait until the family photos are copied.")
    ])

    ContextArchive.DataCase.quiet_oban(fn ->
      ship!(mini)
      ship!(home)
      [source] = Ingest.list_sources!(authorize?: false) |> Enum.filter(&(&1.machine == "home"))
      Ingest.set_source_scope!(source, "personal", authorize?: false)
    end)

    parse_now!(admin)
    judge = Application.get_env(:context_archive, :judge)
    on_exit(fn -> Application.put_env(:context_archive, :judge, judge) end)
    {:ok, admin: admin, mini: mini, reader: mint!("agents-reader", "read", scopes: "agents")}
  end

  defp session!(machine, id, entries) do
    header = %{
      type: "session",
      version: 3,
      id: id,
      timestamp: "2026-09-20T10:00:00.000Z",
      cwd: "/p"
    }

    write_file!(machine, "p/2026-09-20T10-00-00-000Z_#{id}.jsonl", jsonl([header | entries]))
  end

  defp user(id, text),
    do: %{
      type: "message",
      id: id,
      parentId: nil,
      timestamp: "2026-09-20T10:00:01.000Z",
      message: %{role: "user", content: text}
    }

  defp tool_output(id, text),
    do: %{
      type: "message",
      id: id,
      parentId: nil,
      timestamp: "2026-09-20T10:00:02.000Z",
      message: %{
        role: "toolResult",
        toolName: "bash",
        isError: false,
        content: [%{type: "text", text: text}]
      }
    }

  defp find(token, body) do
    {status, resp, _} = HTTP.request(:post, "/api/v1/find", token: token, json: %{data: body})
    {status, resp}
  end

  defp find!(token, body) do
    assert {201, resp} = find(token, body)
    resp
  end

  defp sessions(list), do: Enum.map(list, & &1["document"]["session_id"])

  # The judge on, but at a closed port: only stored answers count, as if TypeSafe were down.
  defp unreachable_judge(overrides \\ []),
    do:
      Application.put_env(
        :context_archive,
        :judge,
        Application.get_env(:context_archive, :judge)
        |> Keyword.merge(enabled: true, url: "http://127.0.0.1:9", timeout_ms: 2_000)
        |> Keyword.merge(overrides)
      )

  defp chunk_ids(session),
    do:
      ContextArchive.Corpus.list_chunks!(authorize?: false)
      |> Enum.filter(&(&1.metadata["session_id"] == session))
      |> Enum.map(& &1.id)

  defp store!(question, session, noul) do
    for id <- chunk_ids(session) do
      Ash.create!(
        ContextArchive.Corpus.Judgment,
        %{
          question_key: Judge.question_key(question),
          chunk_id: id,
          noul: noul,
          model: "jev-test"
        },
        action: :record,
        authorize?: false
      )
    end
  end

  test "with the judge off, candidates come back unjudged, fused across phrasings, each an excerpt around the question's words",
       %{reader: r} do
    # A historical rejection must not filter candidates when judging is disabled.
    store!("Why does the heron migration wait?", @deep, 0.01)

    resp =
      find!(r, %{
        question: "Why does the heron migration wait?",
        queries: ["plover canary"],
        mode: "keyword",
        excerpt_chars: 300
      })

    assert resp["results"] == [] and resp["total"] == 0
    assert resp["judge"]["state"] == "disabled"
    # Both phrasings' finds are candidates: the question's and the second phrasing's.
    found = sessions(resp["unjudged"])
    assert @deep in found and @short in found
    assert Enum.all?(resp["unjudged"], &(&1["score"] == nil))

    deep = Enum.find(resp["unjudged"], &(&1["document"]["session_id"] == @deep))
    assert deep["chars"] > 4000
    assert String.length(deep["excerpt"]) <= 302
    assert deep["excerpt"] =~ "heron migration waits for Friday"
    assert String.starts_with?(deep["excerpt"], "…")
    refute Map.has_key?(deep, "text")
    assert resp["judge"]["cached"] == 0
    assert resp["judge"]["model"] == nil

    body = %{
      question: "Why does the heron migration wait?",
      queries: ["plover canary"],
      mode: "keyword",
      limit: 1
    }

    first = find!(r, body)
    assert first["next_offset"] == 1
    second = find!(r, Map.put(body, :offset, first["next_offset"]))
    refute hd(first["unjudged"])["chunk_id"] == hd(second["unjudged"])["chunk_id"]
    assert first["unjudged_total"] >= 2
  end

  test "a question is plain words: its 'or' doesn't widen the match to any chunk with the last word",
       %{reader: r} do
    # As websearch syntax this would be (heron & migration & finish) | canary, and the
    # Plover note would match on "canary" alone; on the real corpus a common last word
    # ("tool") matched 90,000 chunks and ran past the statement timeout (2026-10-23).
    resp = find!(r, %{question: "Did the heron migration finish or the canary?", mode: "keyword"})

    refute @short in sessions(resp["unjudged"])
    assert resp["searches_incomplete"] == 0
  end

  test "stored answers rank and page the results; nothing below the threshold counts", %{
    reader: r
  } do
    q = "Why does the heron migration wait?"
    store!(q, @deep, 0.93)
    store!(q, @mine, 0.71)
    store!(q, @short, 0.12)
    unreachable_judge()
    body = %{question: q, queries: ["plover canary"], mode: "keyword", limit: 1}

    first = find!(r, body)
    assert sessions(first["results"]) == [@deep]
    assert hd(first["results"])["score"] == 0.93
    assert first["total"] == 2 and first["next_offset"] == 1
    assert first["nearest"] == []

    second = find!(r, Map.put(body, :offset, 1))
    assert sessions(second["results"]) == [@mine]
    assert second["next_offset"] == nil
    # Every candidate had a stored answer, so the unreachable judge was never needed.
    assert second["judge"]["state"] == "ok" and
             second["judge"]["cached"] == second["judge"]["candidates"]
  end

  test "a pinned model does not reuse a moving alias's historical judgments", %{reader: r} do
    q = "Why does the heron migration wait?"
    config = Application.get_env(:context_archive, :judge)
    Application.put_env(:context_archive, :judge, Keyword.put(config, :model, "jev-latest"))
    store!(q, @deep, 0.99)

    Application.put_env(
      :context_archive,
      :judge,
      Keyword.put(config, :model, "jev-1.14.0")
    )

    unreachable_judge()
    resp = find!(r, %{question: q, mode: "keyword"})

    assert resp["judge"]["state"] == "unavailable"
    assert resp["judge"]["cached"] == 0
    assert resp["judge"]["judged"] == 0
    assert resp["judge"]["error"]
    assert resp["results"] == []
    assert @deep in sessions(resp["unjudged"])
    assert Enum.all?(resp["unjudged"], &is_nil(&1["score"]))
  end

  test "the real outgoing request masks the question, passage and metadata", %{reader: r} do
    canary = "sk-" <> String.duplicate("synthetic", 5)
    # Legacy metadata can predate shipper redaction. Only the disposable test DB is touched.
    ContextArchive.Repo.query!("UPDATE documents SET title = $1 WHERE external_id = $2", [
      canary,
      @deep
    ])

    ContextArchive.Repo.query!(
      "UPDATE chunks SET project = $1, text = $1 || ' ' || text WHERE document_id IN (SELECT id FROM documents WHERE external_id = $2)",
      [canary, @deep]
    )

    unreachable_judge()
    Code.ensure_loaded!(Req)
    :erlang.trace_pattern({Req, :post, 2}, true, [:local])
    :erlang.trace(:new, true, [:call, {:tracer, self()}])

    try do
      resp =
        find!(r, %{
          question: "heron migration #{canary}",
          queries: ["heron migration"],
          mode: "keyword"
        })

      assert resp["judge"]["state"] == "unavailable"
      # Observe the real transport call; no HTTP service, function or response is replaced.
      assert_receive {:trace, _, :call, {Req, :post, [_, options]}}, 1_000
      state = options[:json][:state]
      refute Jason.encode!(state) =~ canary
      assert state[:question] =~ "[masked:openai_key]"

      # The first request can be either matching session; collect until the legacy one appears.
      legacy = receive_legacy_request(state)
      assert legacy[:passage][:text] =~ "[masked:openai_key]"
      assert legacy[:passage][:project] == "[masked:openai_key]"
      assert legacy[:passage][:session] == "[masked:openai_key]"
    after
      :erlang.trace(:new, false, [:call])
      :erlang.trace_pattern({Req, :post, 2}, false, [:local])
    end
  end

  defp receive_legacy_request(%{passage: %{session: "[masked:openai_key]"}} = state), do: state

  defp receive_legacy_request(_) do
    assert_receive {:trace, _, :call, {Req, :post, [_, options]}}, 1_000
    receive_legacy_request(options[:json][:state])
  end

  test "the OpenAI-compatible adapter sends a masked chat completion with the configured model and key",
       %{reader: r} do
    canary = "sk-" <> String.duplicate("synthetic", 5)

    unreachable_judge(
      adapter: ContextArchive.Judge.OpenAICompatible,
      model: "judge-test",
      api_key: "test-key"
    )

    Code.ensure_loaded!(Req)
    :erlang.trace_pattern({Req, :post, 2}, true, [:local])
    :erlang.trace(:new, true, [:call, {:tracer, self()}])

    try do
      resp =
        find!(r, %{
          question: "heron migration #{canary}",
          queries: ["heron migration"],
          mode: "keyword"
        })

      assert resp["judge"]["state"] == "unavailable"
      # The real transport call, observed; nothing is replaced.
      assert_receive {:trace, _, :call, {Req, :post, [url, options]}}, 1_000
      assert url == "http://127.0.0.1:9/chat/completions"
      assert {"authorization", "Bearer test-key"} in options[:headers]
      assert options[:json][:model] == "judge-test"
      assert [%{role: "system"}, %{role: "user", content: user}] = options[:json][:messages]
      refute user =~ canary
      assert Jason.decode!(user)["question"] =~ "[masked:openai_key]"
    after
      :erlang.trace(:new, false, [:call])
      :erlang.trace_pattern({Req, :post, 2}, false, [:local])
    end
  end

  test "a configured judge with no address leaves candidates unjudged", %{reader: r} do
    unreachable_judge(url: nil)
    resp = find!(r, %{question: "heron migration", mode: "keyword"})

    assert resp["judge"]["state"] == "unavailable"
    assert resp["judge"]["error"] =~ "no judge url configured"
  end

  test "a full judge outage still pages through more than six unjudged candidates", %{
    reader: r,
    admin: admin,
    mini: mini
  } do
    for n <- 1..8 do
      session!(mini, Ecto.UUID.generate(), [
        user("outage-#{n}", "Heron migration evidence from independent session #{n}.")
      ])
    end

    ship!(mini)
    parse_now!(admin)
    unreachable_judge()
    body = %{question: "heron migration", mode: "keyword", limit: 6}
    first = find!(r, body)

    assert first["judge"]["state"] == "unavailable"
    assert first["results"] == []
    assert first["unjudged_total"] > 6
    assert first["next_offset"] == 6

    second = find!(r, Map.put(body, :offset, first["next_offset"]))
    refute second["unjudged"] == []

    assert MapSet.disjoint?(
             MapSet.new(sessions(first["unjudged"])),
             MapSet.new(sessions(second["unjudged"]))
           )

    assert second["next_offset"] == nil
  end

  test "an exhausted judging budget returns uncached candidates without losing fallback", %{
    reader: r
  } do
    unreachable_judge()

    Application.put_env(
      :context_archive,
      :judge,
      Keyword.put(Application.get_env(:context_archive, :judge), :budget_ms, 0)
    )

    resp = find!(r, %{question: "heron migration", mode: "keyword"})
    assert resp["judge"]["state"] == "unavailable"
    assert resp["judge"]["error"] == "judge time budget exceeded"
    assert resp["judge"]["judged"] == 0
    assert @deep in sessions(resp["unjudged"])
    assert resp["results"] == []
  end

  test "nothing judged to answer: empty results, the nearest misses, and unjudged candidates when the judge is down",
       %{reader: r} do
    q = "Which coffee beans did the team order?"
    store!(q, @deep, 0.08)
    unreachable_judge()
    resp = find!(r, %{question: q, queries: ["heron", "plover"], mode: "keyword"})

    assert resp["results"] == []
    assert sessions(resp["nearest"]) == [@deep]
    assert resp["judge"]["state"] == "partial" and resp["judge"]["error"]
    assert @short in sessions(resp["unjudged"])
  end

  test "the caller's own session is left out, and personal text is never a judge candidate",
       %{reader: r, admin: admin} do
    q = "Why does the heron migration wait?"
    mine = find!(r, %{question: q, mode: "keyword", exclude_session_ids: [@mine]})
    refute @mine in sessions(mine["unjudged"])

    refute @personal in sessions(find!(r, %{question: q, mode: "keyword"})["unjudged"])

    unreachable_judge()
    everything = find!(admin, %{question: q, mode: "keyword"})
    assert @personal in sessions(everything["unjudged"])
    # The judge was only asked about the agents-scope candidates.
    assert everything["judge"]["candidates"] == everything["candidates"] - 1
  end

  test "bad requests are JSON:API errors", %{reader: r} do
    assert {400, %{"errors" => [_ | _]}} = find(r, %{queries: ["x"]})
    assert {400, %{"errors" => [_ | _]}} = find(r, %{question: "x", limit: 99})

    assert {400, %{"errors" => [_ | _]}} =
             find(r, %{question: "x", queries: ["a", "b", "c", "d", "e"]})

    assert {400, %{"errors" => [_ | _]}} = find(r, %{question: "x", mode: "vector"})
  end
end
