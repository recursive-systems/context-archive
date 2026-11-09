defmodule ContextArchive.E2E.ShipperTest do
  @moduledoc """
  The real shipper (`shipper/context_archive_shipper.py`) on a machine's files, sending
  to the running server; what it sends is read back from what the server archived.
  Covers its redaction of credential shapes before upload: masks keep the
  length, so offsets, line boundaries and the head hash hold between runs, also where
  text is kept as a JSON array of byte values (the Grok CLI's bash output).
  """
  use ContextArchive.E2ECase, async: false

  import ContextArchive.SecretShapes

  @moduletag :shipper
  @head 4096

  setup do
    token = mint!("box-ingest", "ingest", source: "box")

    machine =
      machine!("box", token, [
        {"pi-sessions", "append", "**/*.jsonl"},
        {"pi-subagent-runs", "snapshot", "*.json"}
      ])

    {:ok, token: token, box: machine}
  end

  defp lines(data), do: String.split(data, "\n", trim: true)

  defp refute_secrets(data, secrets \\ secrets()) do
    for s <- secrets, do: refute(String.contains?(data, s), "a secret reached the archive")
  end

  describe "redaction" do
    test "every shape is masked in every context, keeping length and prefix",
         %{box: box, token: token} do
      # {value, the part the mask keeps (the rest becomes "*", one for one), its shape}
      values = [
        {gh(), "gh" <> "o_", "github"},
        {gh_pat(), "github" <> "_pat_", "github-pat"},
        {sk_ant(), "sk" <> "-", "sk"},
        {sk(), "sk" <> "-", "sk"},
        {lin(), "lin" <> "_api_", "linear"},
        {fw(), "f" <> "w_", "fireworks"},
        {xoxb(), "xo" <> "xb-", "slack"},
        {"bot" <> tg(), "bot1234567890:", "telegram-bot"},
        {"RESTIC_PASSWORD=" <> restic(), "RESTIC_PASSWORD=", "restic-password"}
      ]

      masked = fn {v, keep, _shape} ->
        keep <> String.duplicate("*", byte_size(v) - byte_size(keep))
      end

      contexts = [
        fn v -> ~s({"t":"#{v}"}) end,
        fn v -> "export X=#{v}" end,
        fn v -> "echo #{v} | cmd" end,
        fn v -> ~S("out":"line\n) <> v <> ~S(\n") end
      ]

      cases = for {v, _, _} = value <- values, c <- contexts, do: {c.(v), c.(masked.(value))}
      local = Enum.map_join(cases, "", fn {src, _} -> src <> "\n" end)
      write_file!(box, "shapes.jsonl", local)

      # Each value alone, as a whole file (no line around it, no newline after it).
      for {{v, _, _}, i} <- Enum.with_index(values),
          do: write_file!(box, "alone-#{i}.json", v, "pi-subagent-runs")

      {0, stats, output} = ship(box)
      refute_secrets(output)

      # Every line is its source with exactly the secret part masked: one mask per line,
      # length and prefix kept.
      archived = archived("box", "shapes.jsonl")
      assert byte_size(archived) == byte_size(local)
      assert lines(archived) == Enum.map(cases, &elem(&1, 1))
      refute_secrets(archived)

      for {value, i} <- Enum.with_index(values) do
        assert archived("box", "pi-subagent-runs", "alone-#{i}.json") == masked.(value)
      end

      # The shipper's own count: 36 lines plus 9 whole files, one mask each, by shape.
      assert stats["redactions"] == %{
               "github" => 5,
               "github-pat" => 5,
               "sk" => 10,
               "linear" => 5,
               "fireworks" => 5,
               "slack" => 5,
               "telegram-bot" => 5,
               "restic-password" => 5
             }

      # And case by case, each in a pass of its own on a machine holding only that file:
      # exactly one mask, of its shape.
      solo =
        for {v, _, shape} = value <- values do
          [{"alone.json", "pi-subagent-runs", v, masked.(value), shape}] ++
            for c <- contexts,
                do:
                  {"line.jsonl", "pi-sessions", c.(v) <> "\n", c.(masked.(value)) <> "\n", shape}
        end

      for {{name, kind, src, expected, shape}, i} <- solo |> List.flatten() |> Enum.with_index() do
        one =
          machine!("box", token, [
            {kind, if(kind == "pi-sessions", do: "append", else: "snapshot"), "*"}
          ])

        write_file!(one, "#{i}-#{name}", src, kind)
        assert %{"redactions" => redactions} = ship!(one)
        assert redactions == %{shape => 1}, src
        assert archived("box", kind, "#{i}-#{name}") == expected
      end
    end

    test "RESTIC_PASSWORD in its assignment forms", %{box: box} do
      forms = [
        "RESTIC_PASSWORD=%s",
        "RESTIC_PASSWORD='%s'",
        ~S(RESTIC_PASSWORD=\"%s\"),
        ~S("RESTIC_PASSWORD": "%s"),
        "export RESTIC_PASSWORD=%s;"
      ]

      local = Enum.map_join(forms, "", &(String.replace(&1, "%s", restic()) <> "\n"))
      write_file!(box, "restic.jsonl", local)
      ship!(box)

      archived = archived("box", "restic.jsonl")
      assert length(lines(archived)) == length(forms)

      for {src, out} <- Enum.zip(lines(local), lines(archived)) do
        refute out =~ restic(), src
        assert byte_size(out) == byte_size(src)
      end
    end

    test "quoted RESTIC_PASSWORD values with spaces and JSON escapes are masked whole",
         %{box: box} do
      words = ~w(correct horse battery staple)
      value = Enum.join(words, " ")

      cases = [
        {"RESTIC_PASSWORD='%s' restic snapshots", value},
        {~S(RESTIC_PASSWORD="%s" restic snapshots), value},
        # a leading space
        {~S(RESTIC_PASSWORD=" %s"), value},
        # JSON-escaped quotes
        {~S({"cmd":"RESTIC_PASSWORD=\"%s\" restic check"}), value},
        # JSON escapes inside the value
        {~S({"cmd":"RESTIC_PASSWORD=\"%s\""}), String.replace(value, " ", ~S(\\))},
        {~S({"RESTIC_PASSWORD": "%s"}), value}
      ]

      local =
        Enum.map_join(cases, "", fn {form, wire} -> String.replace(form, "%s", wire) <> "\n" end)

      write_file!(box, "quoted.jsonl", local)
      ship!(box)

      out_lines = lines(archived("box", "quoted.jsonl"))
      assert length(out_lines) == length(cases)

      for {src, out} <- Enum.zip(lines(local), out_lines) do
        assert byte_size(out) == byte_size(src), src
        for w <- words, do: refute(out =~ w, src)
        # The quotes stay, so the line keeps its shape (and stays valid JSON).
        assert count(out, "\"") == count(src, "\"") and count(out, "'") == count(src, "'"), src
        if String.starts_with?(src, "{"), do: assert({:ok, _} = Jason.decode(out))
      end
    end

    test "escaped quotes inside a RESTIC_PASSWORD value do not end it", %{box: box} do
      parts = ~w(alpha bravo charlie)

      shells = [
        ~S(alpha\"bravo charlie),
        ~S(alpha\\bravo charlie),
        ~S(alpha bravo\"charlie\")
      ]

      srcs =
        for shell <- shells,
            cmd = ~S(RESTIC_PASSWORD=") <> shell <> ~S(" restic check),
            src <- [
              cmd,
              Jason.encode!(%{"cmd" => cmd}),
              Jason.encode!(%{"RESTIC_PASSWORD" => shell})
            ],
            do: src

      local = Enum.map_join(srcs, "", &(&1 <> "\n"))
      write_file!(box, "escaped.jsonl", local)
      ship!(box)

      out_lines = lines(archived("box", "escaped.jsonl"))
      assert length(out_lines) == length(srcs)

      for {src, out} <- Enum.zip(srcs, out_lines) do
        assert byte_size(out) == byte_size(src)
        for p <- parts, do: refute(out =~ p, src)

        if String.starts_with?(src, "{") do
          assert Map.keys(Jason.decode!(out)) == Map.keys(Jason.decode!(src))
        else
          assert String.ends_with?(out, ~S(" restic check)), out
        end
      end
    end

    test "a token used as the user of a URL is masked", %{box: box} do
      urls = [
        "https://%s@github.com/example/repo.git",
        "https://x-access-token:%s@github.com/o/r",
        ~s({"out":"remote: https://%s@github.com/o/r"})
      ]

      srcs = for url <- urls, token <- [gh(), gh_pat()], do: String.replace(url, "%s", token)
      write_file!(box, "urls.jsonl", Enum.map_join(srcs, "", &(&1 <> "\n")))
      ship!(box)

      out_lines = lines(archived("box", "urls.jsonl"))
      assert length(out_lines) == length(srcs)

      for {src, out} <- Enum.zip(srcs, out_lines) do
        refute_secrets(out, [gh(), gh_pat()])
        assert byte_size(out) == byte_size(src)
      end
    end

    test "look-alikes are archived unchanged", %{box: box} do
      blob =
        fake("QmFzZTY0", 60, "Zq9+/") <>
          "fw_" <> fake("", 30, "Ab1") <> "sk-" <> fake("", 30, "Ab1-")

      untouched = [
        # a base64 blob with look-alikes inside
        ~s({"encrypted_content":"gAAAA#{blob}"}),
        # a path, not a password
        "RESTIC_PASSWORD_FILE=/etc/restic/password",
        # 'sk-' inside a word
        "my-task-" <> fake("", 30),
        # not gh[pousr]_
        "ghost_" <> fake("", 36),
        # too short
        "gho_short",
        # bot id too short
        "12345:" <> fake("", 35)
      ]

      local = Enum.map_join(untouched, "", &(&1 <> "\n"))
      write_file!(box, "lookalikes.jsonl", local)
      assert %{"redactions" => redactions} = ship!(box)
      assert redactions == %{}
      assert archived("box", "lookalikes.jsonl") == local
    end

    test "no mask crosses a line break", %{box: box} do
      local = "sk-\n" <> String.duplicate("a", 40) <> "\nRESTIC_PASSWORD=\nx\n"
      write_file!(box, "split.jsonl", local)
      ship!(box)
      assert archived("box", "split.jsonl") == local
    end

    test "text kept as a JSON array of byte values is masked like text, still JSON",
         %{box: box} do
      # The Grok CLI keeps bash output as text and as bytes: "output":[101,120,...].
      out = "export X=#{gh()}\nRESTIC_PASSWORD=#{restic()}\nok\n"
      bytes = :binary.bin_to_list(out)
      compact = Jason.encode!(%{"output" => bytes, "text" => out}) <> "\n"
      spaced = ~s({"output": [) <> Enum.map_join(bytes, ", ", &Integer.to_string/1) <> "]}\n"
      local = compact <> spaced
      write_file!(box, "bytes.jsonl", local)

      # Each secret three times: the compact line's text and bytes, the spaced line's bytes.
      assert %{"redactions" => redactions} = ship!(box)
      assert redactions == %{"github" => 3, "restic-password" => 3}

      archived = archived("box", "bytes.jsonl")
      assert byte_size(archived) == byte_size(local)

      masked =
        "export X=" <>
          "gh" <>
          "o_" <>
          String.duplicate("*", byte_size(gh()) - 4) <>
          "\nRESTIC_PASSWORD=" <> String.duplicate("*", byte_size(restic())) <> "\nok\n"

      [a, b] = lines(archived)
      assert %{"output" => a_bytes, "text" => ^masked} = Jason.decode!(a)
      assert :binary.list_to_bin(a_bytes) == masked
      assert :binary.list_to_bin(Jason.decode!(b)["output"]) == masked
    end

    test "number lists that are not credentials are archived unchanged", %{box: box} do
      local =
        Enum.map_join(
          [
            Jason.encode!(%{"output" => :binary.bin_to_list("plain output, no tokens\n")}),
            Jason.encode!(%{"ids" => [1200, 3400, 5600, 7800, 9100, 1100, 1300, 1500]}),
            "1,2,3,4,5,6,7,8,9,10,11,12 and 0.5,1.5,2.5"
          ],
          "",
          &(&1 <> "\n")
        )

      write_file!(box, "numbers.jsonl", local)
      assert %{"redactions" => redactions} = ship!(box)
      assert redactions == %{}
      assert archived("box", "numbers.jsonl") == local
    end
  end

  describe "shipping" do
    test "ships redacted bytes of the same length, then only what is new", %{box: box} do
      lines =
        in_context()
        |> Enum.with_index()
        |> Enum.map(fn {s, i} ->
          Jason.encode!(%{"n" => i, "text" => "token #{s} here"}) <> "\n"
        end)

      path = write_file!(box, "a.jsonl", Enum.join(lines))

      {0, stats, output} = ship(box)
      refute output =~ gh()
      data = archived("box", "a.jsonl")
      assert byte_size(data) == File.stat!(path).size
      refute_secrets(data)
      assert count(data, "\n") == length(lines)
      assert stats["redactions"] |> Map.values() |> Enum.sum() >= length(secrets())

      # A second run: nothing new, no new generation.
      assert %{"bytes" => 0, "new_generations" => 0} = ship!(box)

      # Growth: only the new line goes, redacted, at the old offset.
      File.write!(path, Jason.encode!(%{"late" => lin()}) <> "\n", [:append])
      assert %{"new_generations" => 0, "batches" => 1} = ship!(box)
      assert generation("box", "a.jsonl") == 0
      data = archived("box", "a.jsonl")
      assert byte_size(data) == File.stat!(path).size
      refute data =~ lin()
    end

    test "a root with `since` skips files last modified before that date", %{box: box} do
      old = write_file!(box, "old.jsonl", ~s({"n":1}\n))
      write_file!(box, "new.jsonl", ~s({"n":2}\n))
      File.touch!(old, DateTime.to_unix(~U[2026-08-15 12:00:00Z]))

      config = Jason.decode!(File.read!(box.config))

      roots =
        Enum.map(config["roots"], fn
          %{"kind" => "pi-sessions"} = r -> Map.put(r, "since", "2026-10-01")
          r -> r
        end)

      File.write!(box.config, Jason.encode!(Map.put(config, "roots", roots)))

      assert %{"files" => 1} = ship!(box)
      assert archived("box", "new.jsonl") == ~s({"n":2}\n)
      assert generations("box", "pi-sessions", "old.jsonl") == []

      # Modified again after the date: shipped whole.
      File.write!(old, ~s({"n":3}\n), [:append])
      ship!(box)
      assert archived("box", "old.jsonl") == ~s({"n":1}\n{"n":3}\n)
    end

    test "only complete lines go; a line still being written waits", %{box: box, token: t} do
      path = write_file!(box, "s.jsonl", ~s({"a":1}\n{"b":))
      ship!(box)
      assert archived("box", "s.jsonl") == ~s({"a":1}\n)

      File.write!(path, ~s(2}\n), [:append])
      ship!(box)
      assert archived("box", "s.jsonl") == ~s({"a":1}\n{"b":2}\n)

      assert {200, %{"streams" => %{"s.jsonl" => %{"offset" => 16, "generation" => 0}}}} =
               stream_state(t, "box", "pi-sessions")
    end

    test "a rewritten file starts a new generation; the archived one stays", %{box: box} do
      path = write_file!(box, "s.jsonl", "first version\nmore\n")
      ship!(box)

      File.write!(path, "second\n")
      assert %{"new_generations" => 1} = ship!(box)

      assert generations("box", "pi-sessions", "s.jsonl") ==
               [{0, "first version\nmore\n"}, {1, "second\n"}]
    end

    test "a token across the head boundary does not start a new generation", %{box: box} do
      path =
        write_file!(
          box,
          "a.jsonl",
          ~s({"p": "#{String.duplicate("x", @head - 20)}", "t": "#{gh_pat()}"}\n)
        )

      ship!(box)

      File.write!(path, "{}\n", [:append])
      {0, stats, _} = ship(box)
      assert stats["new_generations"] == 0
      refute archived("box", "a.jsonl") =~ gh_pat()
    end

    test "the longest escaped RESTIC_PASSWORD value across the head boundary is stable",
         %{box: box} do
      prefix = ~S({"cmd":"RESTIC_PASSWORD=\")
      # 512 JSON-escaped shell backslash escapes, 4 bytes each
      value = String.duplicate(~S(\\\\), 512)
      line = prefix <> value <> ~S(\" restic check"}) <> "\n"
      # The value starts at byte 4095.
      pad = @head - 2 - byte_size(~s({"p":"",)) - byte_size(prefix) + byte_size(~s({"))

      padded =
        ~s({"p":") <>
          String.duplicate("x", pad) <> ~s(",) <> binary_part(line, 1, byte_size(line) - 1)

      assert {:ok, _} = Jason.decode(padded)
      assert :binary.match(padded, value) |> elem(0) == @head - 1

      path = write_file!(box, "a.jsonl", padded)
      ship!(box)
      refute archived("box", "a.jsonl") =~ value

      File.write!(path, "{}\n", [:append])
      {0, stats, _} = ship(box)
      assert stats["new_generations"] == 0
    end

    test "a token in a byte array across the head boundary does not start a new generation",
         %{box: box} do
      bytes = :binary.bin_to_list("token #{gh_pat()} here")
      # The array starts just before byte 4096; the token's bytes run across it.
      prefix = ~s({"p":") <> String.duplicate("x", @head - 120) <> ~s(","output":[)
      line = prefix <> Enum.join(bytes, ",") <> "]}\n"
      assert byte_size(prefix) < @head and byte_size(line) > @head + 200

      path = write_file!(box, "b.jsonl", line)
      ship!(box)

      File.write!(path, "{}\n", [:append])
      {0, stats, _} = ship(box)
      assert stats["new_generations"] == 0

      [first | _] = lines(archived("box", "b.jsonl"))
      refute first |> Jason.decode!() |> Map.fetch!("output") |> :binary.list_to_bin() =~ gh_pat()
    end

    test "a stream archived before redaction with a token in its head starts a redacted generation",
         %{box: box, token: t} do
      raw = Jason.encode!(%{"t" => gh()}) <> "\n"
      write_file!(box, "a.jsonl", raw)
      # Shipped before redaction: the archive holds the raw bytes.
      legacy_ship!(t, "box", "a.jsonl", raw)

      assert %{"new_generations" => 1} = ship!(box)
      assert generation("box", "a.jsonl") == 1
      refute archived("box", "a.jsonl") =~ gh()
      # The earlier generation is never rewritten.
      assert [{0, ^raw}, {1, _}] = generations("box", "pi-sessions", "a.jsonl")
    end

    test "a stream archived before redaction with a clean head just continues",
         %{box: box, token: t} do
      raw = ~s({"hello":1}\n)
      write_file!(box, "a.jsonl", raw <> Jason.encode!(%{"t" => fw()}) <> "\n")
      legacy_ship!(t, "box", "a.jsonl", raw)

      assert %{"new_generations" => 0} = ship!(box)
      assert generation("box", "a.jsonl") == 0
      data = archived("box", "a.jsonl")
      assert String.starts_with?(data, raw)
      refute data =~ fw()
    end

    test "snapshot files are redacted, and an unchanged one is not sent again", %{box: box} do
      write_file!(
        box,
        "r.json",
        Jason.encode!(%{"env" => "RESTIC_PASSWORD=" <> restic(), "k" => xoxb()}),
        "pi-subagent-runs"
      )

      ship!(box)
      data = archived("box", "pi-subagent-runs", "r.json")
      refute data =~ restic()
      refute data =~ xoxb()

      # The content hash of the redacted bytes is stable, so nothing goes.
      assert %{"bytes" => 0} = ship!(box)
    end
  end

  defp count(s, sub), do: length(:binary.matches(s, sub))
end
