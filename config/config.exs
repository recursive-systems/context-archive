# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :ash_oban, pro?: false

config :context_archive, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  # parse: one stream at a time per slot; embed: a single process owns the model.
  queues: [default: 10, parse_stream: 2, embed: 1],
  lifeline: [rescue_after: {2, :hours}],
  pruner: [max_age: {1, :day}],
  repo: ContextArchive.Repo,
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"* * * * *", ContextArchive.Corpus.EmbedWorker}]}
  ]

# Nx on CPU through EXLA (embeddings).
config :nx, default_backend: EXLA.Backend
config :context_archive, :embeddings, enabled: true

# Optional relevance judging for find. Off unless a judge is configured (see
# config/runtime.exs and docs/judging.md). Only masked agents-scope text leaves the archive.
config :context_archive, :judge,
  enabled: false,
  adapter: nil,
  scopes: ["agents"],
  concurrency: 10,
  timeout_ms: 20_000

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  default_string_length_count: :codepoints,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :json_api,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:json_api, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :context_archive,
  ecto_repos: [ContextArchive.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [ContextArchive.Access, ContextArchive.Ingest, ContextArchive.Corpus]

# pgvector support for Postgrex (AshPostgres's vector extension).
config :context_archive, ContextArchive.Repo, types: ContextArchive.PostgrexTypes

# Source kinds this archive accepts, with the access scope every document from them
# inherits and how the shipper sends them. A kind not listed here is rejected at
# ingest, so adding one (and choosing its scope) is always a deliberate change.
# Scopes: "agents" (readable by agents with a read token), "personal" (owner only).
# `adapter` builds corpus rows from the raw bytes; nil means archived raw only.
config :context_archive, :source_kinds, %{
  "pi-sessions" => %{
    scope: "agents",
    mode: :append,
    adapter: ContextArchive.Corpus.Adapters.PiSession
  },
  "pi-subagent-runs" => %{scope: "agents", mode: :snapshot, adapter: nil},
  "claude-sessions" => %{
    scope: "agents",
    mode: :append,
    adapter: ContextArchive.Corpus.Adapters.ClaudeSession
  },
  "codex-sessions" => %{
    scope: "agents",
    mode: :append,
    adapter: ContextArchive.Corpus.Adapters.CodexSession
  },
  "grok-sessions" => %{
    scope: "agents",
    mode: :append,
    adapter: ContextArchive.Corpus.Adapters.GrokSession
  },
  "agy-sessions" => %{
    scope: "agents",
    mode: :append,
    adapter: ContextArchive.Corpus.Adapters.AgySession
  }
}

# Configure the endpoint
config :context_archive, ContextArchiveWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ContextArchiveWeb.ErrorHTML, json: ContextArchiveWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ContextArchive.PubSub,
  live_view: [signing_salt: "bE9XygjT"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :context_archive, ContextArchive.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  context_archive: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  context_archive: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
