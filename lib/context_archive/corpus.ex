defmodule ContextArchive.Corpus do
  @moduledoc """
  The generic, source-independent model built from raw streams by adapters.

    * `Document` - a conversation or thread (a Pi session, later an iMessage thread)
    * `Record` - one ordered item inside documents (a Pi entry, later a message).
      Identified by the hash of its raw bytes, so copies in forked sessions are one row.
    * `DocumentRecord` - which records belong to which documents, with byte provenance
    * `Chunk` - searchable text derived from a record, full-text indexed
    * `Embedding` - a vector per chunk per embedding model
    * `Judgment` - a judge's answer about a chunk for a question (`find`'s cache)
  """
  use Ash.Domain, otp_app: :context_archive, extensions: [AshJsonApi.Domain]

  json_api do
    authorize? true
  end

  resources do
    resource ContextArchive.Corpus.Document do
      define :list_documents, action: :read
      define :get_document, action: :read, get_by: [:id]
      define :set_document_title, action: :set_title, args: [:title]
    end

    resource ContextArchive.Corpus.Record do
      define :list_records, action: :read
    end

    resource ContextArchive.Corpus.DocumentRecord

    resource ContextArchive.Corpus.Chunk do
      define :list_chunks, action: :read
    end

    resource ContextArchive.Corpus.Embedding
    resource ContextArchive.Corpus.Judgment

    resource ContextArchive.Corpus.Search do
      define :search, action: :search
      define :find, action: :find
      define :read_document, action: :document
      define :chunk_context, action: :context
      define :archive_status, action: :status
    end
  end
end
