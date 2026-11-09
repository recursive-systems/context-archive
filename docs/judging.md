# Judging

`find` can ask a judge model whether each candidate passage helps answer the question,
and return only the passages that pass. It is off unless configured; without it, `find`
returns its candidates unjudged and everything else works the same.

## Turning it on

Set these in the environment (`.env` with Docker Compose; read in `config/runtime.exs`):

| variable | meaning |
|---|---|
| `CONTEXT_ARCHIVE_JUDGE` | `openai` (any OpenAI-compatible API) or `typesafe`; empty means off |
| `CONTEXT_ARCHIVE_JUDGE_URL` | the API base, e.g. `https://api.openai.com/v1`, `https://openrouter.ai/api/v1` or `http://127.0.0.1:11434/v1` (Ollama) |
| `CONTEXT_ARCHIVE_JUDGE_MODEL` | the model; required for `openai`, `typesafe` defaults to a pinned Jev |
| `CONTEXT_ARCHIVE_JUDGE_API_KEY_FILE` | a file holding the API key (or `CONTEXT_ARCHIVE_JUDGE_API_KEY`) |

Adapters:

- **`openai`** (`ContextArchive.Judge.OpenAICompatible`): one chat completion per passage,
  at temperature 0, asking for `{"answer": true}` or `{"answer": false}`. Yes scores 1.0,
  no 0.0. Works with any provider or local server that speaks `/chat/completions`.
- **`typesafe`** (`ContextArchive.Judge.TypeSafe`): TypeSafe Jev through a typesafe-proxy
  that holds the API key (this service holds none). One Noul (a score from 0 to 1) per
  passage; the model is pinned to `jev-1.14.0` unless configured.

A new judge is a module implementing `ContextArchive.Judge.Adapter` (`ask/3` and
`default_model/0`) plus one line in `config/runtime.exs`.

## How it works

`find` judges up to about 30 candidates and returns passages scoring at least 0.5, best
first. Each candidate gets at most one attempt; all calls share a ten-second budget (the
`budget_ms` setting, capped at 10,000). When the judge fails or the budget runs out, the
remaining candidates come back in `unjudged` and can still be paged.

Only `agents`-scope text is ever sent, and only masked text (what search returns): the
whole request, question and metadata included, is masked for known secret shapes.
`personal` candidates always come back unjudged.

Answers are kept in the `judgments` table, keyed by question, model and prompt version,
so a repeated question or a further page asks the judge nothing. Changing the model or
the prompt uses a new cache key; old judgments are kept. The question asked is in
`lib/context_archive/judge.ex`; bump `@prompt_version` when changing it.

## Turning it off

Unset `CONTEXT_ARCHIVE_JUDGE` and restart. `find` then returns `judge.state: "disabled"`,
an empty `results` list and every candidate in `unjudged` with a null score
(`unjudged_total` counts them; `offset`/`next_offset` page through them). An empty
judged list does not mean nothing relevant exists. Search, ingestion, reads and stored
judgments are unchanged. Never delete archive data or judgment rows to disable judging.
