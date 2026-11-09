defmodule ContextArchive.Corpus.Search do
  @moduledoc """
  The read API: generic actions only, exposed over AshJsonApi (and so in the OpenAPI
  document agent tool gateways import). Scopes always come from the caller's token; text is
  masked unless an admin token asks for `unmasked`.
  """
  use Ash.Resource,
    otp_app: :context_archive,
    domain: ContextArchive.Corpus,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ContextArchive.Corpus.{Finder, Reader, SearchEngine}

  json_api do
    type "search"

    routes do
      base "/v1"
      route :post, "/search", :search
      route :post, "/find", :find
      route :get, "/documents/:document", :document
      route :get, "/chunks/:chunk_id/context", :context
      route :get, "/status", :status
    end
  end

  actions do
    action :search, :map do
      description """
      Find passages across archived context. Hybrid mode fuses keyword (full-text) and
      semantic (embedding) rankings; keyword mode is best for exact strings (commands,
      paths, error codes). Near-duplicate passages are collapsed into one (its `duplicates`
      counts the rest) and at most 3 come from one session unless you set `per_session`.
      Results are candidates, not judgments: rerank them yourself.
      """

      argument :query, :string, allow_nil?: false, description: "What to look for."

      argument :mode, :atom,
        default: :hybrid,
        constraints: [one_of: [:hybrid, :keyword, :vector]],
        description: "hybrid (default), keyword or vector."

      argument :limit, :integer,
        default: 20,
        constraints: [min: 1, max: 100],
        description: "Number of results (1-100)."

      argument :machines, {:array, :string},
        description: "Only these machines (e.g. mini, growth)."

      argument :projects, {:array, :string}, description: "Only these project directories (cwd)."

      argument :kinds, {:array, :string},
        description:
          "Only these chunk kinds: user, assistant, thinking, tool_call, tool_output, tool_error, summary, subagent_result, extension_message."

      argument :session_ids, {:array, :string},
        description: "Only these sessions (Pi session ids)."

      argument :exclude_session_ids, {:array, :string},
        description:
          "Leave out these sessions and their subagent runs, e.g. your own (PI_SESSION_ID), so you don't find what you just said."

      argument :per_session, :integer,
        constraints: [min: 1, max: 100],
        description:
          "Most passages from one session (default 3; no limit when session_ids is given)."

      argument :dedupe, :boolean,
        default: true,
        description: "Collapse near-duplicate passages into the best-ranked one (default true)."

      argument :after, :utc_datetime_usec,
        description: "Only content at or after this time (ISO 8601)."

      argument :before, :utc_datetime_usec,
        description: "Only content before this time (ISO 8601)."

      argument :errors_only, :boolean, default: false, description: "Only tool and model errors."

      argument :unmasked, :boolean,
        default: false,
        description: "Admin tokens only: return unmasked text."

      run fn input, context ->
        args = input.arguments

        SearchEngine.search(
          query: args.query,
          mode: args.mode,
          limit: args.limit,
          scopes: scopes(context.actor),
          unmasked?: unmasked?(args, context.actor),
          per_session: args[:per_session],
          dedupe: args.dedupe,
          filters: %{
            "machines" => args[:machines],
            "projects" => args[:projects],
            "kinds" => args[:kinds],
            "session_ids" => args[:session_ids],
            "exclude_session_ids" => args[:exclude_session_ids],
            "after" => args[:after],
            "before" => args[:before],
            "errors_only" => args.errors_only
          }
        )
      end
    end

    action :find, :map do
      description """
      Search with a question and up to four more phrasings, fuse the candidates and return
      excerpts around the question's words. A judge model, when configured, decides which
      passages help answer it; `results` is ordered by relevance score and `nearest` shows
      misses when none pass. Only masked agents-scope text is sent to the judge. Excluded or
      failed judgments remain in
      `unjudged` with null scores; evaluate those yourself. If judging is disabled, all
      candidates are explicitly unjudged. Page with `offset` = `next_offset` and read around
      a hit with chunk context. These are historical passages, not verified current facts.
      """

      argument :question, :string,
        allow_nil?: false,
        description: "What you want to know, as a full question."

      argument :queries, {:array, :string},
        constraints: [max_length: 4],
        description:
          "Up to 4 more search phrasings: a paraphrase, and the exact words, names, paths or error text the passage would likely contain."

      argument :limit, :integer,
        default: 6,
        constraints: [min: 1, max: 15],
        description: "Most passages per page (1-15, default 6)."

      argument :offset, :integer,
        default: 0,
        constraints: [min: 0],
        description: "Skip this many passages (next_offset from the last page)."

      argument :excerpt_chars, :integer,
        default: 900,
        constraints: [min: 200, max: 2000],
        description: "Characters of each passage to return (200-2000, default 900)."

      argument :candidates, :integer,
        default: 30,
        constraints: [min: 5, max: 50],
        description: "Fused search candidates to consider (5-50, default 30)."

      argument :threshold, :float,
        default: 0.5,
        constraints: [min: 0.0, max: 1.0],
        description: "Lowest judged score that counts as answering (default 0.5)."

      argument :mode, :atom,
        default: :hybrid,
        constraints: [one_of: [:hybrid, :keyword]],
        description: "hybrid (default) or keyword."

      argument :machines, {:array, :string}, description: "Only these machines (e.g. mini)."
      argument :projects, {:array, :string}, description: "Only these project directories (cwd)."

      argument :kinds, {:array, :string},
        description:
          "Only these chunk kinds (user, assistant, thinking, tool_call, tool_output, ...)."

      argument :exclude_session_ids, {:array, :string},
        description: "Leave out these sessions and their forks and subagent runs, e.g. your own."

      argument :after, :utc_datetime_usec,
        description: "Only content at or after this time (ISO 8601)."

      argument :before, :utc_datetime_usec,
        description: "Only content before this time (ISO 8601)."

      run fn input, context ->
        args = input.arguments

        Finder.find(
          question: args.question,
          queries: args[:queries],
          limit: args.limit,
          offset: args.offset,
          excerpt_chars: args.excerpt_chars,
          candidates: args.candidates,
          threshold: args.threshold,
          mode: args.mode,
          scopes: scopes(context.actor),
          filters: %{
            "machines" => args[:machines],
            "projects" => args[:projects],
            "kinds" => args[:kinds],
            "exclude_session_ids" => args[:exclude_session_ids],
            "after" => args[:after],
            "before" => args[:before]
          }
        )
      end
    end

    action :document, :map do
      description "Read a document (Pi session) in file order, one page of records at a time."

      argument :document, :string,
        allow_nil?: false,
        description: "Document UUID or Pi session id."

      argument :after_offset, :integer,
        description: "Continue after this byte offset (from next_after_offset)."

      argument :limit, :integer, default: 50, constraints: [min: 1, max: 200]
      argument :unmasked, :boolean, default: false, description: "Admin tokens only."

      run fn input, context ->
        args = input.arguments

        Reader.document(args.document, scopes(context.actor),
          after_offset: args[:after_offset],
          limit: args.limit,
          unmasked?: unmasked?(args, context.actor)
        )
        |> not_found()
      end
    end

    action :context, :map do
      description "The records before and after a search hit, in document order."
      argument :chunk_id, :uuid, allow_nil?: false
      argument :before, :integer, default: 5, constraints: [min: 0, max: 50]
      argument :after, :integer, default: 5, constraints: [min: 0, max: 50]
      argument :unmasked, :boolean, default: false, description: "Admin tokens only."

      run fn input, context ->
        args = input.arguments

        Reader.context(args.chunk_id, scopes(context.actor),
          before: args.before,
          after: args.after,
          unmasked?: unmasked?(args, context.actor)
        )
        |> not_found()
      end
    end

    action :status, :map do
      description "Freshness per machine and source, parse and embedding backlog, corpus size."
      run fn _input, context -> Reader.status(scopes(context.actor)) end
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:kind, :read)
      authorize_if actor_attribute_equals(:kind, :admin)
    end
  end

  defp scopes(%{kind: :admin}), do: ContextArchive.Access.Scopes.known()
  defp scopes(%{kind: :read, scopes: scopes}), do: scopes
  defp scopes(_), do: []

  defp unmasked?(args, actor), do: args[:unmasked] == true and match?(%{kind: :admin}, actor)

  defp not_found({:error, :not_found}), do: {:error, Ash.Error.Query.NotFound.exception([])}
  defp not_found(other), do: other
end
