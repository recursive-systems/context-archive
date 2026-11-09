defmodule ContextArchive.DataCase do
  @moduledoc """
  The data side of every test. There is no SQL sandbox: the app, its HTTP server and
  its Oban queues run for real against `context_archive_test` (a database made for
  tests). `reset!/0` pauses the queues until no job runs, empties every table and the
  run's raw-archive directory, then resumes the queues. Tests are serial
  (`async: false`): they share one server, one database and one raw directory.
  """

  alias ContextArchive.Ingest.RawStore
  alias ContextArchive.Repo

  @doc "Empties the test database and the test raw root; refuses anything else."
  def reset! do
    database = Repo.config()[:database]
    %{rows: [[actual]]} = Repo.query!("SELECT current_database()")

    for name <- [database, actual] do
      unless is_binary(name) and String.starts_with?(name, "context_archive_test") do
        raise "refusing to empty #{inspect(name)}: tests only write to context_archive_test*"
      end
    end

    quiet_oban(fn ->
      tables =
        Repo.query!("""
        SELECT quote_ident(tablename) FROM pg_tables
        WHERE schemaname = 'public' AND tablename NOT IN ('schema_migrations', 'oban_peers')
        """).rows
        |> List.flatten()

      Repo.query!("TRUNCATE #{Enum.join(tables, ", ")} RESTART IDENTITY CASCADE")
      empty_raw_root!()
    end)

    :ok
  end

  @doc "The run's raw-archive directory (config/test.exs), checked to be a test one."
  def raw_root! do
    root = RawStore.root()
    tmp = Path.expand(System.tmp_dir!())

    unless Path.dirname(Path.expand(root)) == tmp and
             String.starts_with?(Path.basename(root), "context_archive_test_raw") do
      raise "refusing to use raw root #{inspect(root)}: tests only use #{tmp}/context_archive_test_raw*"
    end

    root
  end

  defp empty_raw_root! do
    root = raw_root!()
    File.rm_rf!(root)
    File.mkdir_p!(root)
  end

  @doc """
  Runs `fun` with every Oban queue paused and idle: pauses them, waits until each
  producer reports itself paused (the pause arrives as a notification) and runs no
  job, so no job (the per-minute cron's included) can start while `fun` runs. Resumes
  the queues afterwards.
  """
  def quiet_oban(fun) do
    :ok = Oban.pause_all_queues()

    try do
      eventually(
        fn ->
          Enum.all?(Oban.config().queues, fn {queue, _} ->
            state = Oban.check_queue(queue: queue)
            state.paused and state.running == []
          end)
        end,
        60_000
      )

      fun.()
    after
      :ok = Oban.resume_all_queues()
    end
  end

  @doc "Polls `fun` until it returns a truthy value, which it returns (the server works on its own)."
  def eventually(fun, timeout \\ 30_000, every \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline, every)
  end

  defp poll(fun, deadline, every) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          ExUnit.Assertions.flunk("condition not met within the timeout")
        else
          Process.sleep(every)
          poll(fun, deadline, every)
        end
    end
  end
end
