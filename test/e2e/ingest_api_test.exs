defmodule ContextArchive.E2E.IngestApiTest do
  @moduledoc """
  The machine-facing intake, `/ingest/v1`, over real HTTP: what the shipper sends and
  what the server keeps. Bytes are read back from the raw archive the server wrote.
  """
  use ContextArchive.E2ECase, async: false

  alias ContextArchive.Ingest.RawStore

  setup do
    {:ok, ingest: mint!("mini-ingest", "ingest", source: "mini")}
  end

  test "health needs no token" do
    assert {200, %{"status" => "ok"}, _} = HTTP.request(:get, "/health")
  end

  test "appends complete lines byte-exactly and advances the offset", %{ingest: t} do
    first = ~s({"a":1}\n{}\n)

    assert {200, %{"generation" => 0, "offset" => 11}} =
             append(t, "mini", first, path: "a/s.jsonl")

    assert {200, %{"generation" => 0, "offset" => 19}} =
             append(t, "mini", ~s({"b":2}\n), path: "a/s.jsonl", offset: 11)

    assert archived("mini", "a/s.jsonl") == ~s({"a":1}\n{}\n{"b":2}\n)

    assert {200, %{"streams" => streams}} = stream_state(t, "mini", "pi-sessions")

    assert %{"a/s.jsonl" => %{"generation" => 0, "offset" => 19, "head_sha256" => head}} =
             streams

    assert head == RawStore.sha256(~s({"a":1}\n{}\n{"b":2}\n))
  end

  test "an uncompressed body is accepted too", %{ingest: t} do
    assert {200, %{"offset" => 4}} =
             append(t, "mini", "one\n", path: "s.jsonl", encoding: nil, body: "one\n")

    assert archived("mini", "s.jsonl") == "one\n"
  end

  test "a stale offset is a 409 conflict that reports the server position", %{ingest: t} do
    assert {200, _} = append(t, "mini", "one\n", path: "s.jsonl")

    assert {409, %{"error" => "conflict", "generation" => 0, "offset" => 4}} =
             append(t, "mini", "one\n", path: "s.jsonl")

    assert {409, %{"error" => "conflict", "offset" => 4}} =
             append(t, "mini", "x\n", path: "s.jsonl", offset: 9)

    # A first write must start at generation 0, byte 0.
    assert {409, %{"generation" => 0, "offset" => 0}} =
             append(t, "mini", "x\n", path: "new.jsonl", offset: 5)

    assert archived("mini", "s.jsonl") == "one\n"
  end

  test "a bad hash and an incomplete last line are refused without writing", %{ingest: t} do
    assert {422, %{"error" => error}} =
             append(t, "mini", "one\n", path: "s.jsonl", sha256: String.duplicate("0", 64))

    assert error =~ "sha256 mismatch"

    assert {422, %{"error" => error}} = append(t, "mini", "partial", path: "s.jsonl")
    assert error =~ "line boundary"

    assert {422, %{"error" => error}} = append(t, "mini", "", path: "s.jsonl")
    assert error =~ "empty batch"

    assert {200, %{"streams" => streams}} = stream_state(t, "mini", "pi-sessions")
    assert streams == %{}
    assert File.ls!(ContextArchive.DataCase.raw_root!()) == []
  end

  test "malformed requests are refused with the reason", %{ingest: t} do
    data = "x\n"

    for {opts, reason} <- [
          {[headers: [{"length", "3"}]], "length mismatch"},
          {[headers: [{"offset", "-1"}]], "bad numeric header"},
          {[headers: [{"generation", nil}]], "missing numeric header"},
          {[headers: [{"mode", "rewrite"}]], "bad mode"},
          {[headers: [{"kind", nil}]], "missing kind"},
          {[headers: [{"path", nil}]], "missing path"},
          {[headers: [{"sha256", nil}]], "missing sha256"},
          {[path: "/etc/passwd"], "path must be relative"},
          {[path: "a/../../b.jsonl"], "path must be relative"},
          {[path: String.duplicate("a", 1025)], "path too long"},
          {[body: "not gzip"], "invalid gzip body"},
          {[encoding: "br"], "unsupported content-encoding"}
        ] do
      opts = Keyword.put_new(opts, :path, "s.jsonl")
      assert {400, %{"error" => ^reason}} = append(t, "mini", data, opts), reason
    end

    assert {400, %{"error" => "missing kind"}} = stream_state(t, "mini", nil)
    assert {200, %{"streams" => %{}}} = stream_state(t, "mini", "pi-sessions")
  end

  test "a rewritten file becomes a new generation; earlier bytes are kept", %{ingest: t} do
    assert {200, _} = append(t, "mini", "old\n", path: "s.jsonl")

    assert {200, %{"generation" => 1, "offset" => 4}} =
             append(t, "mini", "new\n", path: "s.jsonl", generation: 1)

    assert generations("mini", "pi-sessions", "s.jsonl") == [{0, "old\n"}, {1, "new\n"}]

    # Skipping a generation is a conflict, not a gap.
    assert {409, %{"generation" => 1, "offset" => 4}} =
             append(t, "mini", "x\n", path: "s.jsonl", generation: 3)
  end

  test "snapshots store each distinct version once", %{ingest: t} do
    snap = [kind: "pi-subagent-runs", mode: "snapshot", path: "r/status.json"]
    running = ~s({"s":"running"})

    assert {200, %{"generation" => 0}} = append(t, "mini", running, snap)
    # The same content again, even as a "new" generation, is not stored twice.
    assert {200, %{"generation" => 0}} = append(t, "mini", running, snap ++ [generation: 1])

    assert {200, %{"generation" => 1}} =
             append(t, "mini", ~s({"s":"done"}), snap ++ [generation: 1])

    assert generations("mini", "pi-subagent-runs", "r/status.json") ==
             [{0, running}, {1, ~s({"s":"done"})}]

    assert length(ContextArchive.Ingest.list_streams!(authorize?: false)) == 2

    assert {200, %{"streams" => %{"r/status.json" => %{"content_sha256" => sha}}}} =
             stream_state(t, "mini", "pi-subagent-runs")

    assert sha == RawStore.sha256(~s({"s":"done"}))
  end

  test "unknown source kinds are refused", %{ingest: t} do
    assert {422, %{"error" => error}} =
             append(t, "mini", "x\n", path: "x.jsonl", kind: "imessage")

    assert error =~ "not accepted"
  end

  test "sources get the scope configured for their kind", %{ingest: t} do
    admin = mint!("admin", "admin")
    assert {200, _} = append(t, "mini", "x\n", path: "s.jsonl")

    assert {200, %{"sources" => [%{"machine" => "mini", "kind" => "pi-sessions"} = source]}} =
             get(admin, "/api/v1/status")

    assert source["scope"] == "agents"
  end

  test "an uncommitted tail left in the raw file is cut before the next write", %{ingest: t} do
    assert {200, _} = append(t, "mini", "one\n", path: "s.jsonl")

    # What a crash between writing the bytes and committing leaves behind.
    [raw_file] = Path.wildcard(Path.join(ContextArchive.DataCase.raw_root!(), "*/*.bin"))
    File.write!(raw_file, "garbage\n", [:append])

    assert {200, %{"offset" => 8}} = append(t, "mini", "two\n", path: "s.jsonl", offset: 4)
    assert archived("mini", "s.jsonl") == "one\ntwo\n"
  end

  test "lost bytes (a raw file shorter than recorded) are an error, never papered over",
       %{ingest: t} do
    assert {200, _} = append(t, "mini", "one\ntwo\n", path: "s.jsonl")
    [raw_file] = Path.wildcard(Path.join(ContextArchive.DataCase.raw_root!(), "*/*.bin"))
    File.write!(raw_file, "one\n")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {500, %{"error" => "internal error"}} =
                 append(t, "mini", "three\n", path: "s.jsonl", offset: 8)
      end)

    assert log =~ "ingest failed"
    assert File.read!(raw_file) == "one\n"

    assert {200, %{"streams" => %{"s.jsonl" => %{"offset" => 8}}}} =
             stream_state(t, "mini", "pi-sessions")
  end

  test "an ingest token cannot read or write as another machine", %{ingest: t} do
    assert {403, %{"error" => "forbidden"}} = append(t, "growth", "x\n", path: "s.jsonl")
    assert {403, %{"error" => "forbidden"}} = stream_state(t, "growth", "pi-sessions")
  end

  test "read, admin, missing and bogus tokens cannot ingest" do
    read = mint!("reader", "read", scopes: "agents")
    admin = mint!("admin", "admin")

    for token <- [read, admin, nil, "ca_not-a-real-token-at-all-0000000000000"] do
      assert {401, %{"error" => "unauthorized"}} = append(token, "mini", "x\n", path: "s.jsonl")
      assert {401, _} = stream_state(token, "mini", "pi-sessions")
    end
  end

  test "revoked tokens are refused", %{ingest: t} do
    token = mint!("tmp", "ingest", source: "mini")
    assert {200, _} = append(token, "mini", "x\n", path: "s.jsonl")

    # What the operator runs on the VM to revoke a machine's token (there is no API).
    [record] =
      ContextArchive.Access.list_tokens!(authorize?: false) |> Enum.filter(&(&1.name == "tmp"))

    ContextArchive.Access.revoke_token!(record, authorize?: false)

    assert {401, _} = append(token, "mini", "y\n", path: "s.jsonl", offset: 2)
    # The machine's other token still works.
    assert {200, _} = append(t, "mini", "y\n", path: "s.jsonl", offset: 2)
  end
end
