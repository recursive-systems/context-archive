import Config

# Tests run the real thing (README "Testing"): the app, its HTTP server on a free
# loopback port, real Oban queues and the real shipper, against a database made for
# tests. Nothing here is a stand-in.
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :context_archive, ContextArchive.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "context_archive_test#{System.get_env("MIX_TEST_PARTITION")}",
  # No SQL sandbox: the server, Oban and the tests share the real test database,
  # which ContextArchive.DataCase empties before each test.
  pool_size: 10

# The real HTTP server, on a free loopback port (never the service's 4000; see
# config/runtime.exs). Tests reach it over TCP (ContextArchiveWeb.HTTP).
config :context_archive, ContextArchiveWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 0],
  secret_key_base: "VbxZi7n/dQVscz84NcuTSc+qK06FYXkwkFiF0e7nRGHZZHEMz1+xxYKLsPbRQ6pH",
  server: true

# The embedding model is not loaded in tests (minutes of EXLA compilation on the VM);
# search tests use keyword mode. README "Testing" says what that leaves untested.
config :context_archive, :embeddings, enabled: false
# Nothing calls out in tests: find returns its candidates unjudged (or with stored judgments).
# Tests that turn judging on point the TypeSafe adapter at a closed port.
config :context_archive, :judge, enabled: false, adapter: ContextArchive.Judge.TypeSafe

# Tests never touch the persistent raw archive: each run gets its own new directory
# (random name, so runs in other clones on the same machine never share one).
config :context_archive, ContextArchive.Ingest.RawStore,
  root:
    Path.join(
      System.tmp_dir!(),
      "context_archive_test_raw#{System.get_env("MIX_TEST_PARTITION")}_" <>
        Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    )

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
