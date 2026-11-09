defmodule ContextArchive.E2E.ReadApiTest do
  @moduledoc """
  The read API (`/api/v1`, what agent tool gateways import) over real HTTP, on sessions two
  machines sent with the real shipper and the server parsed on its real queues. One
  machine's source is moved to the owner-only `personal` scope the way the README says
  an operator does it (`Ingest.set_source_scope/2`), before its sessions are parsed.
  """
  use ContextArchive.E2ECase, async: false

  alias ContextArchive.Ingest

  import ContextArchive.SecretShapes, only: [gh: 0]

  @moduletag :shipper

  @session "01a0dddd-0000-7000-8000-000000000004"
  @personal "01a0eeee-0000-7000-8000-000000000005"
  # AWS's documented example key: a shape the API masks and the shipper leaves alone.
  @aws_key "AKIA" <> "IOSFODNN7EXAMPLE"
  # A session archived before the shipper redacted anything still holds tokens
  # the shipper now masks, e.g. a GitHub token; the API must mask those too.
  @legacy "01a0ffff-0000-7000-8000-000000000006"

  setup do
    mini_token = mint!("mini-ingest", "ingest", source: "mini")
    mini = machine!("mini", mini_token)
    home = machine!("home", mint!("home-ingest", "ingest", source: "home"))
    admin = mint!("admin", "admin")

    write_file!(
      mini,
      "p/2026-09-20T10-00-00-000Z_#{@session}.jsonl",
      jsonl([
        %{
          type: "session",
          version: 3,
          id: @session,
          timestamp: "2026-09-20T10:00:00.000Z",
          cwd: "/home/debian/project"
        },
        msg("e1", "user", "The gateway returns 402 payment required for Radar"),
        %{
          type: "message",
          id: "e2",
          parentId: "e1",
          timestamp: "2026-09-20T10:00:02.000Z",
          message: %{
            role: "toolResult",
            toolName: "bash",
            isError: true,
            content: [%{type: "text", text: "curl: (22) 402 Payment Required; key #{@aws_key}"}]
          }
        },
        msg("e3", "user", "Unrelated message about gardening")
      ])
    )

    write_file!(
      home,
      "p/2026-09-20T11-00-00-000Z_#{@personal}.jsonl",
      jsonl([
        %{
          type: "session",
          version: 3,
          id: @personal,
          timestamp: "2026-09-20T11:00:00.000Z",
          cwd: "/x"
        },
        msg("p1", "user", "Personal note about the gateway invoice")
      ])
    )

    legacy =
      jsonl([
        %{
          type: "session",
          version: 3,
          id: @legacy,
          timestamp: "2026-09-19T09:00:00.000Z",
          cwd: "/home/debian/project"
        },
        %{
          type: "message",
          id: "g1",
          parentId: nil,
          timestamp: "2026-09-19T09:00:01.000Z",
          message: %{
            role: "toolResult",
            toolName: "bash",
            isError: true,
            content: [%{type: "text", text: "push rejected for token #{gh()}"}]
          }
        }
      ])

    # Nothing parses until the home source is personal (the per-minute cron could).
    ContextArchive.DataCase.quiet_oban(fn ->
      ship!(mini)
      ship!(home)
      legacy_ship!(mini_token, "mini", "p/2026-09-19T09-00-00-000Z_#{@legacy}.jsonl", legacy)
      [source] = Ingest.list_sources!(authorize?: false) |> Enum.filter(&(&1.machine == "home"))
      Ingest.set_source_scope!(source, "personal", authorize?: false)
    end)

    parse_now!(admin)

    {:ok,
     admin: admin,
     reader: mint!("agents-reader", "read", scopes: "agents"),
     ingest: mint!("mini-ingest-2", "ingest", source: "mini")}
  end

  defp msg(id, role, text),
    do: %{
      type: "message",
      id: id,
      parentId: nil,
      timestamp: "2026-09-20T10:00:0#{String.last(id)}.000Z",
      message: %{role: role, content: text}
    }

  test "keyword search finds passages and masks secrets", %{reader: token} do
    results = search!(token, %{query: "402 payment", mode: "keyword"})
    texts = Enum.map(results, & &1["text"])

    assert Enum.any?(texts, &String.contains?(&1, "402 payment required"))
    error = Enum.find(results, &(&1["kind"] == "tool_error"))
    assert error["text"] =~ "[masked:aws_key]"
    refute error["text"] =~ @aws_key
    assert error["document"]["session_id"] == @session
    assert error["machine"] == "mini" and error["scope"] == "agents"
    assert error["record"]["entry_id"] == "e2" and error["record"]["is_error"]
    assert error["source_ref"]["byte_offset"] > 0
    assert is_number(error["score"]) and error["keyword_rank"] >= 1
  end

  test "tokens archived before the shipper redacted are masked too, unmasked for admins only",
       %{reader: reader, admin: admin} do
    for unmasked <- [false, true] do
      [hit] = search!(reader, %{query: "rejected", mode: "keyword", unmasked: unmasked})
      assert hit["text"] == "push rejected for token [masked:github_token]"
    end

    [hit] = search!(admin, %{query: "rejected", mode: "keyword"})
    assert hit["text"] =~ "[masked:github_token]"
    [raw] = search!(admin, %{query: "rejected", mode: "keyword", unmasked: true})
    assert raw["text"] == "push rejected for token #{gh()}"
  end

  test "scopes limit what a token can see", %{reader: reader, admin: admin} do
    agents = search!(reader, %{query: "gateway", mode: "keyword"})
    assert agents != []
    assert Enum.all?(agents, &(&1["scope"] == "agents"))

    everything = search!(admin, %{query: "gateway", mode: "keyword"})
    assert personal = Enum.find(everything, &(&1["scope"] == "personal"))

    # Nor can a reader open the personal session or the context of its hit.
    assert {404, _} = get(reader, "/api/v1/documents/#{@personal}")
    assert {404, _} = get(reader, "/api/v1/chunks/#{personal["chunk_id"]}/context")
    assert {200, _} = get(admin, "/api/v1/documents/#{@personal}")
  end

  test "errors_only, and unmasked text for admin tokens only", %{reader: reader, admin: admin} do
    errors = search!(reader, %{query: "402", mode: "keyword", errors_only: true, unmasked: true})
    assert errors != []
    assert Enum.all?(errors, &(&1["kind"] == "tool_error"))
    assert hd(errors)["text"] =~ "[masked:"

    raw = search!(admin, %{query: "402", mode: "keyword", errors_only: true, unmasked: true})
    assert hd(raw)["text"] =~ @aws_key

    # The same rule for reading a session.
    {200, doc} = get(reader, "/api/v1/documents/#{@session}", unmasked: true)
    refute Enum.any?(doc["records"], &(&1["text"] =~ @aws_key))
    {200, doc} = get(admin, "/api/v1/documents/#{@session}", unmasked: true)
    assert Enum.any?(doc["records"], &(&1["text"] =~ @aws_key))
  end

  test "filters narrow the candidates", %{admin: admin} do
    q = fn extra ->
      search!(admin, Map.merge(%{query: "gateway OR gardening OR 402", mode: "keyword"}, extra))
    end

    assert Enum.all?(q.(%{machines: ["home"]}), &(&1["machine"] == "home"))
    assert [_ | _] = q.(%{machines: ["home"]})
    assert Enum.all?(q.(%{session_ids: [@session]}), &(&1["document"]["session_id"] == @session))
    assert Enum.all?(q.(%{kinds: ["user"]}), &(&1["kind"] == "user"))
    assert Enum.all?(q.(%{projects: ["/x"]}), &(&1["project"] == "/x"))

    before = q.(%{before: "2026-09-20T10:00:02Z", machines: ["mini"]})
    assert Enum.map(before, & &1["record"]["entry_id"]) == ["e1"]
    later = q.(%{after: "2026-09-20T10:00:02Z", machines: ["mini"]})
    assert Enum.sort(Enum.map(later, & &1["record"]["entry_id"])) == ["e2", "e3"]
  end

  test "documents read in order and context surrounds a hit", %{reader: token} do
    {200, doc} = get(token, "/api/v1/documents/#{@session}")
    assert doc["document"]["project"] == "/home/debian/project"
    assert Enum.map(doc["records"], & &1["entry_id"]) == ["e1", "e2", "e3"]

    # The document's own UUID works as well as the session id.
    {200, same} = get(token, "/api/v1/documents/#{doc["document"]["id"]}")
    assert same["records"] == doc["records"]

    [hit] = search!(token, %{query: "gardening", mode: "keyword"})
    {200, ctx} = get(token, "/api/v1/chunks/#{hit["chunk_id"]}/context", before: 1, after: 0)
    assert Enum.map(ctx["records"], & &1["entry_id"]) == ["e2", "e3"]
  end

  test "documents page through their records", %{reader: token} do
    {200, page} = get(token, "/api/v1/documents/#{@session}", limit: 2)
    assert Enum.map(page["records"], & &1["entry_id"]) == ["e1", "e2"]
    assert is_integer(page["next_after_offset"])

    {200, rest} =
      get(token, "/api/v1/documents/#{@session}",
        limit: 2,
        after_offset: page["next_after_offset"]
      )

    assert Enum.map(rest["records"], & &1["entry_id"]) == ["e3"]
    assert rest["next_after_offset"] == nil
  end

  test "status reports sources and embedding coverage per token's scopes",
       %{reader: reader, admin: admin} do
    {200, status} = get(reader, "/api/v1/status")

    assert [%{"machine" => "mini", "kind" => "pi-sessions", "scope" => "agents"} = mini] =
             status["sources"]

    assert status["documents"] == 2
    assert is_integer(mini["bytes"]) and mini["bytes"] > 0
    assert mini["files"] == 2 and mini["unparsed_bytes"] == 0
    assert %{"model" => _, "embeddable_chunks" => n, "coverage" => _} = status["embedding"]
    assert n > 0

    {200, all} = get(admin, "/api/v1/status")

    assert Enum.map(all["sources"], &{&1["machine"], &1["scope"]}) == [
             {"home", "personal"},
             {"mini", "agents"}
           ]

    assert all["documents"] == 3
  end

  test "ingest, missing and bogus tokens cannot read", %{ingest: ingest} do
    assert {401, _} = search(ingest, %{query: "x"})
    assert {401, _} = get(nil, "/api/v1/status")
    assert {401, _} = get("ca_not-a-real-token-at-all-0000000000000", "/api/v1/status")
    assert {401, _} = get(ingest, "/api/v1/documents/#{@session}")
    assert {401, _} = get(nil, "/api/open_api")
  end

  test "bad requests and unknown documents are JSON:API errors", %{reader: token} do
    assert {404, %{"errors" => [_ | _]}} = get(token, "/api/v1/documents/no-such-session")
    assert {400, %{"errors" => [_ | _]}} = search(token, %{query: "x", mode: "fuzzy"})
    assert {400, %{"errors" => [_ | _]}} = search(token, %{query: "x", limit: 500})
    assert {400, %{"errors" => [_ | _]}} = get(token, "/api/v1/chunks/not-a-uuid/context")
  end

  test "the OpenAPI document lists the read routes and not the ingest ones", %{reader: token} do
    {200, spec} = get(token, "/api/open_api")
    spec = if is_binary(spec), do: Jason.decode!(spec), else: spec

    for path <- [
          "/api/v1/search",
          "/api/v1/status",
          "/api/v1/documents/{document}",
          "/api/v1/chunks/{chunk_id}/context"
        ] do
      assert Map.has_key?(spec["paths"], path), path
    end

    refute Enum.any?(Map.keys(spec["paths"]), &String.contains?(&1, "ingest"))
  end

  test "a request the server cannot handle is a plain 500 in the caller's format, and it keeps serving",
       %{reader: reader, ingest: ingest} do
    # Today a NUL byte in a filter is one: PostgreSQL text cannot hold NUL. If that ever
    # becomes a 400, find another request that crashes, or drop this test.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {500, %{"errors" => %{"detail" => "Internal Server Error"}}, _} =
                 HTTP.request(:post, "/api/v1/search",
                   token: reader,
                   json: %{data: %{query: "x", mode: "keyword", session_ids: ["a\u0000b"]}},
                   close: true
                 )

        assert {500, "Internal Server Error", _} =
                 HTTP.request(:get, "/ingest/v1/sources/mini/streams",
                   token: ingest,
                   params: [kind: "a\u0000b"],
                   close: true
                 )

        # Since Bandit 1.13 the crash report can be logged just after the 500 reaches
        # us; give it a moment to land inside the capture.
        Process.sleep(500)
      end)

    assert log =~ "character_not_in_repertoire"
    assert {200, %{"status" => "ok"}, _} = HTTP.request(:get, "/health")
    assert [_ | _] = search!(reader, %{query: "gateway", mode: "keyword"})
  end

  test "unknown pages are 404s in the caller's format" do
    assert {404, %{"errors" => %{"detail" => "Not Found"}}, _} =
             HTTP.request(:get, "/nope", headers: [{"accept", "application/json"}])

    assert {404, "Not Found", _} = HTTP.request(:get, "/nope", headers: [{"accept", "text/html"}])
  end
end
