# Context Archive

Collects agent session logs from every machine, keeps every byte, and indexes them for
keyword and semantic search. `search` returns candidates and never judges; `find` fuses
phrasings and, when a judge is configured, asks it which passages answer the question.
Built with Phoenix, Ash, AshPostgres, AshOban and AshJsonApi. `README.md` and `docs/` have how
it runs, is operated and judges.

## Invariants

- **The archive holds everything agents have seen, secrets included.** Raw bytes and
  the database are append-only history: never delete, rewrite, truncate or reset them
  in a live instance without the owner's explicit approval. Never print raw archive
  content, tokens or credential files into logs, issues or chat.
- Never log SQL or archived content.
- API responses mask secret-looking strings by default; never add an unmasked path a read
  token can reach. Access scopes (`agents`, `personal`) are enforced by token.
- Only masked `agents`-scope text may go to a judge; `personal` text never leaves. Keep each
  judge's model pinned or configured, so a cached judgment never outlives the model that made it.
- Anything specific to one deployment (hosts, networks, judge, paths) is configuration,
  documented with the rest of the setup, never code.

## Care, validation and builds

- Care about the codebase, not only the task: understand the surrounding design, follow
  existing patterns and keep changes small, readable and maintainable.
- `mix precommit` is the build gate. It holds only compilation and fast static checks; keep it
  fast and run it when you finish a change.
- Tests run the real thing end to end against disposable resources, with no mocks, stubs or
  isolated unit tests. They inform; they are not part of the build gate.
- Use fictional fixtures. Never point a test at a live database or raw archive.

## Writing the code

Be idiomatic to Elixir, Ash and Phoenix, and prefer the frameworks' own abstractions over custom
replacements. Before changing framework code, read the usage rules and docs the installed
dependency ships under `deps/<package>/`, at the version in `mix.lock`. Use the dependencies
already here before adding one.
