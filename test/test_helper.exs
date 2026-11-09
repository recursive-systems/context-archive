# Everything runs for real (README "Testing"): the app and its HTTP server are already
# started by `mix test`; tests talk to it over TCP, send files with the real shipper and
# read through the real API. Without python3 (the shipper) or psql (scripts/list-streams.sh)
# the tests that need them are skipped, and this says why.
excluded =
  for {tag, exe, why} <- [
        {:shipper, "python3", "python3 is not installed: the real shipper cannot run"},
        {:psql, "psql", "psql is not installed: scripts/list-streams.sh cannot run"}
      ],
      is_nil(System.find_executable(exe)) do
    IO.puts("Skipping @tag #{tag} tests: #{why}")
    tag
  end

# The run's own raw-archive directory (config/test.exs) goes when the run ends.
ExUnit.after_suite(fn _ -> File.rm_rf!(ContextArchive.DataCase.raw_root!()) end)

ExUnit.start(exclude: excluded)
