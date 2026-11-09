defmodule ContextArchive.Archive do
  @moduledoc """
  The archive as its clients use it, for tests:

    * tokens minted by the real `mix context_archive.mint_token` (what the operator runs
      on the VM) into a new 0600 file;
    * machines sending files with the real shipper (`shipper/context_archive_shipper.py`)
      pointed at the test server, or, for streams archived before redaction,
      raw bytes POSTed to the real ingest API the way the old shipper sent them;
    * parsing on the real Oban queues: `parse_now!/1` enqueues the job the per-minute
      cron enqueues and waits until `/api/v1/status` shows nothing left to parse;
    * the read API over real HTTP.

  `archived/3` and `generations/3` read what the server stored (the raw-archive file of a
  stream), the way `scripts/list-streams.sh` does: observation, never a write.
  """
  import ExUnit.Assertions

  alias ContextArchive.{DataCase, Ingest}
  alias ContextArchive.Ingest.RawStore
  alias ContextArchiveWeb.HTTP

  @shipper Path.expand("../../shipper/context_archive_shipper.py", __DIR__)
  @scripts Path.expand("../../scripts", __DIR__)

  # The shipper and the scripts get no session id and no proxy; the shipper's config names
  # only the test server, and psql only the test database (pg_env/0).
  @clean_env [
    {"PI_SESSION_ID", nil},
    {"HTTPS_PROXY", nil},
    {"HTTP_PROXY", nil},
    {"https_proxy", nil},
    {"http_proxy", nil},
    {"ALL_PROXY", nil}
  ]

  def python, do: System.find_executable("python3")

  ## Tokens

  @doc """
  Mints a token with `mix context_archive.mint_token` and returns its plaintext, read
  from the 0600 file the task writes. `kind` is "ingest", "read" or "admin"; opts
  `:source` (ingest) and `:scopes` (read, comma-separated).
  """
  def mint!(name, kind, opts \\ []) do
    dir = private_dir!("context-archive-test-tokens-")
    out = Path.join(dir, name)

    args =
      ["--name", name, "--kind", kind, "--out", out] ++
        if(opts[:source], do: ["--source", opts[:source]], else: []) ++
        if(opts[:scopes], do: ["--scopes", opts[:scopes]], else: [])

    ExUnit.CaptureIO.capture_io(fn -> Mix.Task.rerun("context_archive.mint_token", args) end)

    %File.Stat{mode: mode} = File.stat!(out)
    assert Bitwise.band(mode, 0o777) == 0o600
    token = out |> File.read!() |> String.trim()
    File.rm_rf!(dir)
    token
  end

  ## Ingest API (what the shipper speaks)

  @doc """
  POSTs `data` to `/ingest/v1/sources/:machine/append` exactly as the shipper does
  (gzip body, X-Archive-* headers). `headers` override or drop (`nil`) single headers;
  `body:` replaces the gzipped body; `encoding: nil` drops Content-Encoding.
  Returns `{status, body}`.
  """
  def append(token, machine, data, opts) do
    defaults = %{
      "kind" => opts[:kind] || "pi-sessions",
      "mode" => opts[:mode] || "append",
      "path" => Keyword.fetch!(opts, :path),
      "generation" => to_string(opts[:generation] || 0),
      "offset" => to_string(opts[:offset] || 0),
      "length" => to_string(byte_size(data)),
      "sha256" => opts[:sha256] || RawStore.sha256(data)
    }

    archive_headers =
      defaults
      |> Map.merge(Map.new(opts[:headers] || []))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {"x-archive-" <> k, v} end)

    encoding =
      case Keyword.get(opts, :encoding, "gzip") do
        nil -> []
        enc -> [{"content-encoding", enc}]
      end

    headers = [{"content-type", "application/octet-stream"} | encoding] ++ archive_headers
    body = Keyword.get_lazy(opts, :body, fn -> :zlib.gzip(data) end)

    {status, resp, _} =
      HTTP.request(:post, "/ingest/v1/sources/#{machine}/append",
        token: token,
        headers: headers,
        body: body
      )

    {status, resp}
  end

  @doc """
  Sends a whole file's raw bytes the way the shipper did before it redacted anything:
  a stream archived then holds the original bytes. Must succeed.
  """
  def legacy_ship!(token, machine, path, data, opts \\ []) do
    assert {200, %{"offset" => offset}} =
             append(token, machine, data, Keyword.put(opts, :path, path))

    assert offset == (opts[:offset] || 0) + byte_size(data)
    :ok
  end

  @doc "GET /ingest/v1/sources/:machine/streams?kind=K: `{status, body}`."
  def stream_state(token, machine, kind) do
    {status, body, _} =
      HTTP.request(:get, "/ingest/v1/sources/#{machine}/streams",
        token: token,
        params: if(kind, do: [kind: kind], else: [])
      )

    {status, body}
  end

  ## The real shipper

  @doc """
  A machine set up to run the real shipper against the test server: a private temp
  directory with the ingest token in a 0600 file and a shipper.json whose roots are
  `roots` (`{kind, mode, glob}`; each gets its own directory). Returns a map with
  `:dir`, `:config`, `:machine`, and `:roots` (kind => local directory).
  """
  def machine!(name, token, roots \\ [{"pi-sessions", "append", "**/*.jsonl"}]) do
    dir = private_dir!("context-archive-test-machine-")
    token_file = Path.join(dir, "ingest.token")
    File.write!(token_file, token <> "\n")
    File.chmod!(token_file, 0o600)

    specs =
      for {kind, mode, glob} <- roots do
        path = Path.join(dir, kind)
        File.mkdir_p!(path)
        %{"kind" => kind, "path" => path, "mode" => mode, "glob" => glob}
      end

    config = Path.join(dir, "shipper.json")

    File.write!(
      config,
      Jason.encode!(%{
        "url" => HTTP.base_url(),
        "source" => name,
        "token_file" => token_file,
        "roots" => specs
      })
    )

    File.chmod!(config, 0o600)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)

    %{
      dir: dir,
      config: config,
      machine: name,
      roots: Map.new(specs, &{&1["kind"], &1["path"]})
    }
  end

  @doc "Writes a file under a machine's root for `kind` (default pi-sessions); returns its path."
  def write_file!(machine, rel, data, kind \\ "pi-sessions") do
    path = Path.join(machine.roots[kind], rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
    path
  end

  @doc """
  Runs one pass of the real shipper for `machine`. Returns `{exit_code, stats, output}`:
  `stats` is the JSON line it prints, `output` everything it printed (stdout + stderr).
  """
  def ship(machine) do
    {output, code} =
      System.cmd(python(), [@shipper, "--config", machine.config],
        env: @clean_env,
        stderr_to_stdout: true
      )

    stats =
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find_value(fn line ->
        case Jason.decode(line) do
          {:ok, %{"files" => _} = stats} -> stats
          _ -> nil
        end
      end)

    {code, stats, output}
  end

  @doc "Runs the shipper; it must succeed. Returns its stats."
  def ship!(machine) do
    {code, stats, output} = ship(machine)
    assert code == 0, "shipper failed (#{code}): #{output}"
    assert stats["errors"] == 0, output
    stats
  end

  ## Byte-for-byte verification (scripts/list-streams.sh | scripts/verify-archive.py)

  @doc """
  Runs the operator's check for `machine` as the README shows it: the VM's
  `scripts/list-streams.sh <machine>` piped into `scripts/verify-archive.py` with the
  machine's shipper config, here pointed at the test database and raw root. Returns
  `{exit_code, stats, output}`.
  """
  def verify_archive(machine) do
    db = ContextArchive.Repo.config()[:database]
    %{rows: [[actual]]} = ContextArchive.Repo.query!("SELECT current_database()")

    unless String.starts_with?(db, "context_archive_test") and actual == db do
      raise "refusing to list streams of #{inspect(db)}: tests only read context_archive_test*"
    end

    cmd =
      "bash #{shell_quote(Path.join(@scripts, "list-streams.sh"))} #{shell_quote(machine.machine)}" <>
        " | #{shell_quote(python())} #{shell_quote(Path.join(@scripts, "verify-archive.py"))} " <>
        shell_quote(machine.config)

    {output, code} =
      System.cmd("bash", ["-o", "pipefail", "-c", cmd],
        env:
          @clean_env ++
            [
              {"CONTEXT_ARCHIVE_DB", db},
              {"CONTEXT_ARCHIVE_RAW_ROOT", DataCase.raw_root!()}
            ] ++ pg_env(),
        stderr_to_stdout: true
      )

    [first | _] = String.split(output, "\n")
    {code, Jason.decode!(first), output}
  end

  # psql reaches exactly the server the app uses (config/runtime.exs): host or socket
  # directory, port, user and password from the Repo, and nothing inherited that libpq
  # would prefer (PGHOSTADDR, a service file) or add (PGDATABASE, PGOPTIONS).
  defp pg_env do
    c = ContextArchive.Repo.config()

    [
      {"PGHOST", c[:socket_dir] || c[:hostname]},
      {"PGPORT", c[:port] || 5432},
      {"PGUSER", c[:username]},
      {"PGPASSWORD", c[:password]},
      {"PGHOSTADDR", nil},
      {"PGSERVICE", nil},
      {"PGSERVICEFILE", nil},
      {"PGDATABASE", nil},
      {"PGOPTIONS", nil},
      {"PGPASSFILE", nil}
    ]
    |> Enum.map(fn {k, v} -> {k, v && to_string(v)} end)
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  ## Parsing (real Oban)

  @doc """
  Parses everything received so far on the real queues: enqueues the parse scheduler
  (the job its per-minute cron enqueues) and waits until `/api/v1/status`, read with
  an admin token, shows no unparsed bytes in any source and no parse job (scheduler or
  worker, both on the `parse_stream` queue) is waiting or running: the worker moves the
  parse mark before its action finishes.
  """
  def parse_now!(admin_token) do
    AshOban.schedule(Ingest.Stream, :parse)

    DataCase.eventually(fn ->
      {200, status} = get(admin_token, "/api/v1/status")

      Enum.all?(status["sources"], &(&1["unparsed_bytes"] == 0)) and
        Oban.check_queue(queue: :parse_stream).running == [] and
        ContextArchive.Repo.query!("""
        SELECT count(*) FROM oban_jobs
        WHERE queue = 'parse_stream'
          AND state IN ('available', 'scheduled', 'executing', 'retryable')
        """).rows == [[0]]
    end)

    :ok
  end

  ## Read API

  @doc "POST /api/v1/search with `body` as JSON:API data: `{status, body}`."
  def search(token, body) do
    {status, resp, _} =
      HTTP.request(:post, "/api/v1/search", token: token, json: %{data: body})

    {status, resp}
  end

  @doc "A search that must succeed: its results."
  def search!(token, body) do
    assert {201, %{"results" => results}} = search(token, body)
    results
  end

  @doc "GET with a token: `{status, body}`."
  def get(token, path, params \\ []) do
    {status, body, _} = HTTP.request(:get, path, token: token, params: params)
    {status, body}
  end

  ## Observation of what the server stored

  @doc "All generations of a machine's file, oldest first, as `{generation, raw bytes}`."
  def generations(machine, kind, rel) do
    Ingest.list_streams!(authorize?: false, load: [:source])
    |> Enum.filter(&(&1.path == rel and &1.source.machine == machine and &1.source.kind == kind))
    |> Enum.sort_by(& &1.generation)
    |> Enum.map(&{&1.generation, File.read!(RawStore.path(&1.source_id, &1.id))})
  end

  @doc "The archived bytes of the file's latest generation."
  def archived(machine, kind \\ "pi-sessions", rel) do
    case generations(machine, kind, rel) do
      [] -> flunk("#{machine}:#{kind}:#{rel} was never archived")
      gens -> gens |> List.last() |> elem(1)
    end
  end

  @doc "The latest generation number of the file."
  def generation(machine, kind \\ "pi-sessions", rel) do
    machine |> generations(kind, rel) |> List.last() |> elem(0)
  end

  ## Data

  @doc "JSONL of maps (one JSON object per line)."
  def jsonl(entries), do: Enum.map_join(entries, "", &(Jason.encode!(&1) <> "\n"))

  @doc "A new private directory (random name, created exclusively, mode 0700)."
  def private_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        prefix <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    dir
  end
end
