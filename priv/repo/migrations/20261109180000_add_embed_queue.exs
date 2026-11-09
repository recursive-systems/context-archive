defmodule ContextArchive.Repo.Migrations.AddEmbedQueue do
  @moduledoc """
  A narrow queue of the chunks that still need a vector for the current embedding model.

  Finding and counting the backlog used to anti-join every `embed?` chunk against every
  embedding, which grows with the archive and outgrew the query timeout. The embed worker
  and /status now read only this queue. A trigger adds each new `embed?` chunk (chunks are
  insert-only, with content-derived IDs); the worker removes chunks once their vectors are
  stored. The backfill below is the last full anti-join.
  """

  use Ecto.Migration

  # The model the backfill checks; it must equal ContextArchive.Embeddings.model_name/0.
  @model "bge-small-en-v1.5"

  def up do
    create table(:embed_queue, primary_key: false) do
      add :chunk_id,
          references(:chunks,
            column: :id,
            name: "embed_queue_chunk_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          primary_key: true

      add :scope, :text, null: false
      add :occurred_at, :utc_datetime_usec
    end

    execute "CREATE INDEX embed_queue_occurred_at_index ON embed_queue (occurred_at DESC NULLS LAST)"
    create index(:embed_queue, [:scope])

    execute """
    CREATE FUNCTION embed_queue_add() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO embed_queue (chunk_id, scope, occurred_at)
      VALUES (NEW.id, NEW.scope, NEW.occurred_at)
      ON CONFLICT DO NOTHING;
      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER chunks_embed_queue AFTER INSERT ON chunks
    FOR EACH ROW WHEN (NEW."embed?") EXECUTE FUNCTION embed_queue_add()
    """

    execute """
    INSERT INTO embed_queue (chunk_id, scope, occurred_at)
    SELECT c.id, c.scope, c.occurred_at
    FROM chunks c
    WHERE c."embed?"
      AND NOT EXISTS (
        SELECT 1 FROM embeddings e WHERE e.chunk_id = c.id AND e.model = '#{@model}'
      )
    ON CONFLICT DO NOTHING
    """

    # /status counts embeddable chunks per scope; this keeps that count off the chunks heap.
    execute ~s|CREATE INDEX chunks_embeddable_scope_index ON chunks (scope) WHERE "embed?"|
  end

  def down do
    execute "DROP INDEX chunks_embeddable_scope_index"
    execute "DROP TRIGGER chunks_embed_queue ON chunks"
    execute "DROP FUNCTION embed_queue_add()"
    drop table(:embed_queue)
  end
end
