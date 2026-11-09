defmodule ContextArchive.E2E.VerifyArchiveTest do
  @moduledoc """
  The operator's byte-for-byte check, as the README runs it: the VM's
  `scripts/list-streams.sh <machine>` piped into `scripts/verify-archive.py` on the
  machine's shipper config. Here the listing comes from the test database and raw
  directory, and the archive was filled by the real shipper and, for streams from
  before redaction, by raw POSTs to the real ingest API.
  """
  use ContextArchive.E2ECase, async: false

  import ContextArchive.SecretShapes

  @moduletag :shipper
  @moduletag :psql

  setup do
    token = mint!("box-ingest", "ingest", source: "box")

    box =
      machine!("box", token, [
        {"pi-sessions", "append", "**/*.jsonl"},
        {"pi-subagent-runs", "snapshot", "*.json"}
      ])

    {:ok, token: token, box: box}
  end

  # Over the first 4096 bytes, so a token-holding line never changes the head hash and
  # an old stream keeps growing in place (the only way a stream ends up mixed).
  @pad ~s({"pad":"#{String.duplicate("p", 5000)}"}\n)

  test "redacted and pre-redaction streams both verify", %{box: box, token: t} do
    write_file!(box, "a.jsonl", Jason.encode!(%{"t" => sk()}) <> "\n{}\n")
    ship!(box)

    # Archived before redaction: the server holds the raw bytes.
    raw = Jason.encode!(%{"t" => sk()}) <> "\n"
    write_file!(box, "b.jsonl", raw)
    legacy_ship!(t, "box", "b.jsonl", raw)

    {code, stats, output} = verify_archive(box)
    assert code == 0, output
    assert stats["checked"] == 2
    assert {stats["match"], stats["match_unredacted"], stats["mismatch"]} == {1, 1, 0}
    refute output =~ sk()
  end

  test "a stream that crossed the switch verifies; a changed file does not",
       %{box: box, token: t} do
    old = @pad <> Jason.encode!(%{"t" => gh()}) <> "\n" <> ~s({"t":"plain"}\n)
    path = write_file!(box, "a.jsonl", old)
    legacy_ship!(t, "box", "a.jsonl", old)

    # The machine's new shipper sends the rest redacted, in the same generation.
    File.write!(
      path,
      Jason.encode!(%{"t" => fw()}) <> "\n" <> Jason.encode!(%{"t" => lin()}) <> "\n",
      [:append]
    )

    assert %{"new_generations" => 0} = ship!(box)
    archived = archived("box", "a.jsonl")
    assert archived =~ gh()
    refute archived =~ fw()

    {code, stats, output} = verify_archive(box)
    assert {code, stats["match_mixed"], stats["mismatch"]} == {0, 1, 0}, output

    # The local file no longer matches what was archived: a mismatch, named.
    File.write!(path, String.replace(File.read!(path), ~s({"t":"plain"}), ~s({"t":"PLAIN"})))
    {code, stats, output} = verify_archive(box)
    assert {code, stats["mismatch"]} == {1, 1}
    assert output =~ "mismatch: pi-sessions:a.jsonl gen=0"
    refute output =~ gh()
  end

  test "too many switch points is unverified, not a mismatch", %{box: box, token: t} do
    line = fn i -> Jason.encode!(%{"t" => gh(), "n" => i}) <> "\n" end
    old = @pad <> Enum.map_join(0..34, "", line)
    path = write_file!(box, "a.jsonl", old)
    legacy_ship!(t, "box", "a.jsonl", old)

    File.write!(path, Enum.map_join(35..69, "", line), [:append])
    assert %{"new_generations" => 0} = ship!(box)

    {code, stats, output} = verify_archive(box)
    assert {code, stats["unverified"], stats["mismatch"]} == {0, 1, 0}, output
    assert output =~ "unverified"
  end

  test "a snapshot matching neither the raw nor the redacted file is a mismatch",
       %{box: box} do
    path = write_file!(box, "r.json", Jason.encode!(%{"k" => xoxb()}), "pi-subagent-runs")
    ship!(box)
    assert {0, %{"match" => 1}, _} = verify_archive(box)

    File.write!(path, "other")
    {code, stats, _} = verify_archive(box)
    assert {code, stats["mismatch"], stats["match_mixed"]} == {1, 1, 0}
  end

  test "files purged locally count as missing, not as mismatches", %{box: box} do
    path = write_file!(box, "gone.jsonl", "{}\n")
    ship!(box)
    File.rm!(path)

    assert {0, %{"missing_locally" => 1, "mismatch" => 0}, _} = verify_archive(box)
  end
end
