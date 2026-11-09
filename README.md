# Context Archive

A small self-hosted service that keeps every agent session you run, on every machine,
and lets your agents search it.

- **Collect:** a stdlib-only Python shipper on each machine pushes new bytes of session
  logs every couple of minutes, masking known credential shapes before they leave.
- **Keep:** the server stores every byte append-only, so nothing is ever lost or rewritten.
- **Search:** sessions are parsed into chunks with a full-text index and local embeddings
  (pgvector). `search` returns ranked candidates; `find` fuses several phrasings and can
  ask a judge model which passages answer the question.

Built with Elixir, Phoenix and Ash on PostgreSQL. Supported sources: Pi, Claude Code,
Codex, Grok CLI and Antigravity CLI sessions. Each is one adapter in
`lib/context_archive/corpus/adapters`, so a new source is a new adapter.

```text
 laptop ─┐                                  ┌─ agents: search, find (HTTP + OpenAPI)
servers ─┼─ shipper (push, every ~2 min) ─► Context Archive
  later ─┘                                  ├─ raw bytes, append-only
                                            ├─ Postgres: documents, records, chunks
                                            └─ full-text index + pgvector embeddings
```

## Quick start

With Docker:

```sh
cp .env.example .env        # set POSTGRES_PASSWORD and SECRET_KEY_BASE
docker compose up -d --build
docker compose exec app bin/context_archive rpc \
  'ContextArchive.Release.mint(name: "laptop-ingest", kind: "ingest", source: "laptop", out: "/data/tokens/laptop.token")'
docker compose exec app bin/context_archive rpc \
  'ContextArchive.Release.mint(name: "agents-reader", kind: "read", scopes: "agents", out: "/data/tokens/reader.token")'
```

The archive listens on `127.0.0.1:4000`. To reach it from other machines, put a
TLS-terminating reverse proxy or Tailscale Serve in front, and keep it off the public
internet. Copy each token out of the `data` volume to the machine that uses it.

From source (Elixir 1.17+, PostgreSQL with pgvector): `mix setup`, `mix phx.server`, and
`mix context_archive.mint_token` with the same options as above.

On each machine, save its ingest token as `~/.config/context-archive/ingest.token` and
write `~/.config/context-archive/shipper.json` (both mode 0600):

```json
{"url": "https://archive.example",
 "source": "laptop",
 "token_file": "~/.config/context-archive/ingest.token",
 "roots": [{"kind": "claude-sessions", "path": "~/.claude/projects", "mode": "append", "glob": "**/*.jsonl"}]}
```

Then run `shipper/install`, which sets up a LaunchAgent on macOS or a systemd user timer
on Linux. Source kinds: `pi-sessions`, `claude-sessions`, `codex-sessions`,
`grok-sessions` and `agy-sessions` (Antigravity CLI conversations exported to JSONL;
the exporter is not part of this repo yet).

## API

Every request needs a bearer token (`Authorization: Bearer <token>`). Read tokens carry
scopes; admin tokens see every scope and may ask for unmasked text.

| method | path | what |
|---|---|---|
| POST | `/api/v1/search` | ranked candidates: `hybrid` (keyword + vector), `keyword` or `vector`, with filters by machine, project, kind, session and date; near-duplicates collapse |
| POST | `/api/v1/find` | a question plus up to 4 phrasings, fused and paged; judged passages in `results`, the rest in `unjudged` |
| GET | `/api/v1/documents/{document}` | a whole session, in file order, paged |
| GET | `/api/v1/chunks/{chunk_id}/context` | the records before and after a hit |
| GET | `/api/v1/status` | freshness per machine and source, parse and embedding backlog |
| GET | `/api/open_api` | the OpenAPI document, for agent tool gateways |

Every result carries its scores, masked text, the session and record it came from, and
the byte range in the raw archive. Full parameters are in the OpenAPI document.

### Judging (optional)

`find` can ask a judge model whether each candidate passage answers the question and
return only those that pass: any OpenAI-compatible API (OpenAI, OpenRouter, a local
Ollama) or TypeSafe Jev, set with `CONTEXT_ARCHIVE_JUDGE` and friends. Only masked
`agents`-scope text is ever sent. Off by default; `find` then returns unjudged
candidates. See [docs/judging.md](docs/judging.md).

## Security

The archive holds everything your agents have seen, including credentials that showed
up in tool output. So: keep it on a private network, every request needs a token, the
shipper masks known credential shapes before upload, API responses mask anything
secret-looking, and read tokens carry scopes (`agents` for agent sessions, `personal`
for owner-only sources). SQL and archived content are never logged.

## More

- [docs/operations.md](docs/operations.md): deployment, tokens, verification, testing, backups
- [docs/judging.md](docs/judging.md): how judging works and how to turn it off
- `AGENTS.md`: conventions for coding agents working in this repo

## License

MIT, see [LICENSE](LICENSE).
