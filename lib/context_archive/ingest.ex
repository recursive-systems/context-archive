defmodule ContextArchive.Ingest do
  @moduledoc """
  Byte-exact, append-only intake from machines.

  A `Source` is one kind of data on one machine (e.g. `mini` + `pi-sessions`).
  A `Stream` is one generation of one file of a source; a file that is rewritten
  or truncated gets a new generation instead of overwriting archived bytes.
  A `Batch` is one accepted byte range: the ingest ledger.
  """
  use Ash.Domain, otp_app: :context_archive

  resources do
    resource ContextArchive.Ingest.Source do
      define :register_source, action: :register, args: [:machine, :kind]
      define :set_source_scope, action: :set_scope, args: [:scope]
      define :list_sources, action: :read
    end

    resource ContextArchive.Ingest.Stream do
      define :append_bytes, action: :append
      define :stream_state, action: :state, args: [:machine, :kind]
      define :mark_stream_parsed, action: :mark_parsed, args: [:bytes_parsed]
      define :list_streams, action: :read
      define :get_stream, action: :read, get_by: [:id]
    end

    resource ContextArchive.Ingest.Batch do
      define :list_batches, action: :read
    end
  end
end
