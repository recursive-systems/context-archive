# Operations

Running, verifying and backing up a Context Archive deployment. See the [README](../README.md) for what it is and the API.

For most installs, use Docker Compose (README "Quick start"). The VM sections below
describe one reference deployment: a persistent Debian 13 arm64 VM reached over
Tailscale Serve, with restic backups. Tailscale is that deployment's choice, not a
requirement; any private network or TLS-terminating reverse proxy works.

## Chunks

Chunk kinds: `user`, `assistant`, `thinking`, `tool_call`, `tool_output`, `tool_error`,
`summary`, `subagent_result`, `extension_message`. Embedded: conversation, thinking,
tool-call summaries, every error, summaries, subagent results, head+tail digests of
`bash`/tool-gateway/job output. Everything, including file reads, is keyword-searchable.

Machine-written extension messages (event or audit logs written into sessions) can be kept
keyword-only so they don't fill the vector index: list their Pi `customType`s in
`CONTEXT_ARCHIVE_KEYWORD_ONLY_TYPES` (comma-separated), restart, then run
`ContextArchive.Release.apply_keyword_only_types()` once (`mix run --no-start -e` on the VM,
`bin/context_archive eval` in Docker) to take chunks of those types off the embedding queue.

## Operating it

```sh
# Tokens: plaintext only ever goes to a new 0600 file.
mix context_archive.mint_token --name <machine>-ingest --kind ingest --source <machine> --out PATH
mix context_archive.mint_token --name agents-reader --kind read --scopes agents --out PATH
# Shipper on a machine (config ~/.config/context-archive/shipper.json, 0600):
shipper/install            # LaunchAgent (macOS) or systemd user timer (Linux), every 2 min
# Prefix diagnostic of what a machine shipped:
ssh context-archive 'bash context-archive/scripts/list-streams.sh <machine>' \
  | python3 scripts/verify-archive.py ~/.config/context-archive/shipper.json
```

### Opt-in full-file inclusion verification

The original invocation remains a prefix diagnostic: append streams may match while
local bytes beyond the uploaded prefix remain unarchived, and local-only files are
not enumerated. For deliberate full-file verification, supply an explicit nonempty
JSON array of candidates, for example `candidates.json`:

```json
[
  {
    "kind": "pi-sessions",
    "path": "legacy/project/example.jsonl",
    "local_path": "/home/owner/legacy-archive/project/example.jsonl"
  }
]
```

`kind` and `path` identify the archived stream; `path` must be a relative path without
empty, `.` or `..` components. `local_path` must be the actual absolute local path,
with no tilde or environment expansion. It may deliberately name an unconfigured
legacy location. No shipper config is read, no roots are changed or guessed, and no
alternative local file is inferred. Include every file the owner intends to check,
including files with no known server entry. Files outside this candidate list are
not checked. Duplicate stream identities, duplicate local paths, and multiple
candidates resolving to the same device/inode fail verification. File symlinks are
rejected; the owner can instead explicitly supply a resolved regular-file path.

The operator supplies a bounded server manifest for the matching machine from the existing
`list-streams.sh` output: six TSV fields, `kind`, `mode`, relative `path`, `generation`,
committed `bytes_received`, and actual stored SHA256. The verifier trusts this supplied
listing and performs no server requests. Use a fresh receipt directory whose parent
already exists, belongs to the current user and is owner-only (`0700`). Creation and
opening are anchored to that parent's descriptor.

```sh
python3 scripts/verify-archive.py --full-file \
  --candidates /path/to/candidates.json \
  --receipts-dir /path/to/private/full-file-receipts \
  < /path/to/matching-server.tsv
```

Full-file mode hashes the entire local regular file, including any final fragment
without a newline, using both original bytes and the shipper's length-preserving
redaction. It requires EOF, equal local and committed server sizes, and stable
device, inode, size, nanosecond mtime and ctime before/after hashing, checking both
the open file and its path. Run against quiescent files; a receipt is an observation
at verification time, not a promise about subsequent writes. Lines larger than 8 MiB
are explicitly unverified rather than allowing file-sized memory allocations.

Each candidate receives a numbered JSON receipt in manifest order. The new directory
has owner-only permissions (`0700`), and receipt files are owner-only (`0600`, subject
to a more restrictive umask). Existing directories and files are never overwritten.
Receipts contain paths, resolved identity, stream metadata, full sizes and hashes,
status and a concrete failure reason, never file content. `exact` means the complete
original bytes match; `redacted` proves only masked content inclusion and does not
preserve the masked originals. `mixed_unverified` means neither full hash matches
and historical mixed redaction is possible, not proven. Full-file mode deliberately
does not attempt the prefix diagnostic's historical switch-point search.

Missing local/server files, partial uploads, instability, ambiguous server matches
(even identical duplicate rows), malformed/empty inputs, hash mismatches and unverified
mixed cases exit nonzero. Malformed candidate manifests are rejected before receipts
are created. Empty or malformed server input fails every valid candidate. Stdout
contains aggregate counts only; inspect the private receipts for per-file results.

Receipts are **CONTENT-INCLUSION ONLY**, never deletion certificates. Full EOF/hash
inclusion is only one requirement. Before any retirement, the owner separately checks
parsing, independent raw/database backup coverage, native resume and other local
consumer requirements, and exact preservation of anything masked. Receipts make no
backup, parsing or local-consumer promise. The owner decides release, live checks and any
relocation.

Source kinds and their scopes and adapters are configured in `config/config.exs`
(`:source_kinds`); an unconfigured kind is rejected at ingest. Change a source's scope
with `ContextArchive.Ingest.set_source_scope/2` (documents and chunks carry the scope
and must be updated with it).

PostgreSQL cannot store NUL in text/jsonb, so database copies replace it with U+FFFD;
the raw archive keeps the exact bytes. SQL is never logged (`log: false`) and the
service logs at info level, so archived content stays out of the journal.

## Reference deployment

- One **persistent** Debian 13 ARM64 VM (Incus here), hostname `context-archive`;
  `ssh context-archive` reaches it. 2 CPU, 4 GiB RAM, 100 GiB disk, autostart, nightly
  backups.
- Checkout: `/home/debian/context-archive`, owned by `debian`.
- Application: `context-archive.service`, a lingering systemd **user** service, dev mode.
- Web: `127.0.0.1:4000`, privately proxied by Tailscale Serve (HTTPS 443).
- Tailnet: node tagged `tag:context-archive`; the tailnet policy admits only the machines
  that ship to it or read from it, on 443.
- Database: PostgreSQL 18 from PGDG with **pgvector** (created in `template1`, so every
  app database has it); loopback only; peer authentication over `/var/run/postgresql`.
  Memory settings (1 GB `shared_buffers` for a 4 GiB VM) are in
  `/etc/postgresql/18/main/conf.d/context-archive.conf`, written by `bootstrap-vm.sh`.
- DB role: `debian`, CREATEDB but neither SUPERUSER nor CREATEROLE; no DB password.
- Toolchain: Elixir 1.20.4 / Erlang/OTP 29.1.2 under `/opt/context-archive`, checksum-verified
  Hex ARM64 builds.
- Embeddings: Bumblebee + EXLA on CPU (see `spikes/`), fastembed through Pythonx as the
  fallback.

## Components

| piece | where | what |
|---|---|---|
| shipper | `shipper/context_archive_shipper.py`, on each machine | stdlib-only Python; pushes new complete lines of append-only files and whole new versions of rewritten files; verified byte ranges; server is the authority on offsets; rewritten files become new generations; masks known credential shapes (GitHub, `sk-` keys, Linear, Fireworks, Slack, Telegram bot tokens, `RESTIC_PASSWORD=`) before upload, keeping lengths so offsets hold, also where a file holds text as a JSON array of byte values (Grok's bash output); tested end to end against the server (see Testing) |
| ingest | this app | per-machine ingest tokens; byte-exact append-only raw store; ingest ledger |
| corpus | this app | generic `Source` → `Document` → `Record` → `Chunk` → `Embedding`; one adapter per source kind (Pi sessions first); entries copied into forked sessions stored once |
| search | this app | hybrid keyword + vector retrieval with metadata filters; masked output; scope-aware tokens; OpenAPI for agent tools |

## Bootstrap

Create a Debian 13 VM named `context-archive` (2 CPU, 4 GiB RAM, 100 GiB disk), for
example with Incus:

```sh
incus launch images:debian/13 context-archive --vm \
  -c limits.cpu=2 -c limits.memory=4GiB -c boot.autostart=true -d root,size=100GiB
```

Clone this repository to `/home/debian/context-archive` on the VM, then as root:
`bash scripts/bootstrap-vm.sh`.

Then, as `debian` in the checkout: `mix setup`, and as root
`bash scripts/install-services.sh`. Tailscale: `sudo tailscale up --hostname=context-archive`
(owner browser login), then `sudo bash scripts/serve-tailnet.sh`.

## Development on the VM

```sh
ssh context-archive
cd ~/context-archive
export CONTEXT_ARCHIVE_LOCAL_DB=1     # already exported by the VM login profile
mix setup
mix precommit                         # compile and format checks only, no tests
systemctl --user status context-archive
systemctl --user restart context-archive
journalctl --user -u context-archive -n 100 --no-pager
curl --fail http://127.0.0.1:4000/health
```

Never run `mix ecto.reset` against the persistent dev DB.

### Deploying to the VM

The service runs straight from the checkout, so the checkout is the deployment. Stop
the service before moving the checkout: dev mode reloads changed code into a running
instance, which would then run something other than what it reports. Shippers retry.

```sh
cd ~/context-archive
git fetch origin
systemctl --user stop context-archive
git merge --ff-only origin/main
mix deps.get && mix ash.migrate          # only when mix.lock or migrations changed
systemctl --user start context-archive
curl --fail http://127.0.0.1:4000/health # answers once the app has compiled and started
```

`/health` answers `{"status":"ok","revision":"<commit>","started_at":"<UTC time>"}`: the
commit the instance was started from (`-dirty` appended if the working tree differed from
it, `null` if it could not be read) and when it started. `/api/v1/status` carries the same
under `build`. A deploy is done when `revision` is the commit you meant to ship.

## Validation and periodic checks

`mix precommit` runs compilation and formatting checks only, never tests. Measure their
combined elapsed time and keep it under 60 seconds. Do not add, maintain or run unit-test
suites. Keep any temporary local check minimal and ephemeral.

Use periodic light integration/E2E checks outside the build, never as build/deploy
blockers. Report failures as production-health issues to fix or roll back. Prefer safe
normal-path observation and preserve a credible rollback. Use fictional fixtures or
staging whenever a check could affect data, access, money or external messages. Keep
runtime, authorization, data-integrity and spend safeguards.

The existing end-to-end harness uses fictional fixtures, no mocks, stubs or isolated
unit tests. `mix test` starts the whole app with its HTTP server on a free loopback port
and its Oban queues running, then:

- sends files the way machines do: the real shipper (`shipper/context_archive_shipper.py`)
  on files a test writes, pointed at the test server; streams from before the shipper
  redacted are made the way they happened, by POSTing raw bytes to `/ingest/v1`;
- parses them on the real queues: a test enqueues the job the per-minute cron enqueues
  and waits until `/api/v1/status` shows nothing left to parse;
- reads through the read API over HTTP with tokens minted by
  `mix context_archive.mint_token`, and runs the operator's byte-for-byte check
  (`scripts/list-streams.sh | scripts/verify-archive.py`) on what was archived;
- writes only to `context_archive_test<MIX_TEST_PARTITION>`, a database made for tests
  (no SQL sandbox; the application and job tables emptied before each test with the
  queues paused and idle, any other database refused), and
  to a new raw directory under the system temp dir, removed when the run ends. Tests are
  serial. They never read `context_archive_dev` or `/srv/context-archive/raw`.

Where the API does not show something (a chunk's `embed?` flag, shared record rows), a
test reads the test database. Operator steps with no API (revoking a token, moving a
source to the `personal` scope, forcing a re-parse) use the same functions the operator
runs on the VM. Nothing in the app calls out: the shipper's config names only the test
server and psql only the test database (no inherited PGHOSTADDR, service file or psqlrc),
so the tests reach only the server they start and the test database. To prove it on the
VM: `PGUSER=debian unshare -rn sh -c 'ip link set lo up && mix test'` (loopback only).

Not tested: vector and hybrid search with the real model. The embedding model is not
loaded in the test env (minutes of EXLA compilation on the VM's two CPUs), so search
tests use keyword mode. The shipper tests need `python3`, the byte-for-byte check `psql`;
without them those tests skip with a printed reason.

Run them on the VM, in your own clone and partition when other work may be running
(the live checkout's own `mix test` is safe too: it uses `_build/test`, the test database
and a temp directory, and never the service's port):

```sh
cd ~/context-archive-<task>
mix precommit                                    # measured build/static checks, no tests
MIX_TEST_PARTITION=_<task> mix test                # periodic E2E only, outside the build
```

## Backups

Nightly append-only restic backups (set up outside this repo) go to a separate host.
A root-owned `ExecStartPre` hook first writes an atomic custom-format `pg_dump` of
`context_archive_dev` plus a globals dump to `/srv/context-archive/backups`; a dump
failure aborts the backup. Restic covers `/root /home /etc /srv /var/lib/tailscale`,
so the raw archive, dumps and Tailscale identity are included. The raw archive is
append-only, so a dump taken before the file backup never references bytes the same
snapshot lacks.

`sudo bash scripts/verify-backup.sh` restores the latest dump into a disposable database.

Recovery: restore files from the correct host snapshot (the dump and the raw archive
from the **same** snapshot); reinstall the pinned runtime/PostgreSQL (`bootstrap-vm.sh`,
which also creates pgvector in `template1`); create a new database owned by `debian`,
then `pg_restore --no-owner --no-comments --role=debian`. `--no-comments` is required:
the extension already exists and the non-superuser role cannot re-comment on it.
Never restore over `context_archive_dev` without explicit approval, and never run two
machines with the same restored Tailscale identity.

## Running in dev mode

The reference deployment runs the dev build, so `config/dev.exs` disables Phoenix's
request debugger at **compile time**. The matching runtime flag is not sufficient:
changing it cannot remove debugger code already compiled into the endpoint. Keep
generic HTML/JSON error rendering and the info-level, SQL-disabled logging; never add
request headers, archived content or credential values to diagnostics.

## Rules for the reference VM

- The reference deployment's persistent VM is `context-archive` (`ssh context-archive`); it is NOT an ephemeral coding box.
- Canonical working checkout on the VM: `/home/debian/context-archive`. Read `README.md` and `docs/operations.md`
  before service, database, networking or backup work.
- Run as `debian`. `CONTEXT_ARCHIVE_LOCAL_DB=1` uses local PostgreSQL peer authentication;
  `context_archive_dev` is persistent state and `context_archive_test` is disposable.
- App: `systemctl --user status|restart context-archive`; logs:
  `journalctl --user -u context-archive`. It runs in dev mode with reload.
- HTTP stays on `127.0.0.1:4000`; PostgreSQL, SSH, desktop and browser-debug ports are
  never published. Private Tailscale Serve only, never Funnel.
- **The archive holds everything agents have seen, secrets included.** Raw bytes under
  `/srv/context-archive/raw` and the database are append-only history: never delete,
  rewrite, truncate or reset them without explicit owner approval. Never print raw
  archive content, tokens or credential files into logs, issues or chat.
- API responses mask secret-looking strings by default; do not add unmasked paths
  reachable by agents (e.g. through a tool gateway). Access scopes (`agents`, `personal`) are enforced by
  token; `personal` sources (e.g. iMessage) are owner-only.
- Never delete/recreate the VM or drop `context_archive_dev` without explicit approval.
  Confirm before pushes to shared branches or external actions.
