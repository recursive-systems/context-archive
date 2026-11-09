defmodule ContextArchive.Embeddings do
  @moduledoc """
  Local text embeddings with Bumblebee + EXLA on CPU (bge-small-en-v1.5, 384 dims).

  Two servings share one loaded model:

    * `ContextArchive.Embeddings.Bulk` - batch 16, for the backfill/new-chunk worker
    * `ContextArchive.Embeddings.Query` - batch 1, so a search query is not padded to 16

  Measured on the context-archive VM (2 vCPU, Pi 5): ~3.4 texts/s at 256 tokens.
  Chunks are split to at most 900 characters so they fit the 256-token window.
  Disabled in tests (`config :context_archive, :embeddings, enabled: false`).
  """

  @repo {:hf, "BAAI/bge-small-en-v1.5"}
  @model_name "bge-small-en-v1.5"
  # bge v1.5 retrieval instruction for queries (passages are embedded as-is).
  @query_prefix "Represent this sentence for searching relevant passages: "

  def model_name, do: @model_name

  def enabled?, do: Application.get_env(:context_archive, :embeddings, [])[:enabled] != false

  @doc "Supervisor children for the servings (empty when disabled)."
  def child_specs do
    if enabled?() do
      {:ok, model_info} = Bumblebee.load_model(@repo)
      {:ok, tokenizer} = Bumblebee.load_tokenizer(@repo)

      [
        {Nx.Serving,
         serving: serving(model_info, tokenizer, 16, [128, 256]),
         name: ContextArchive.Embeddings.Bulk,
         batch_timeout: 50},
        {Nx.Serving,
         serving: serving(model_info, tokenizer, 1, [64, 128, 256]),
         name: ContextArchive.Embeddings.Query,
         batch_timeout: 5}
      ]
    else
      []
    end
  end

  defp serving(model_info, tokenizer, batch_size, sequence_lengths) do
    Bumblebee.Text.text_embedding(model_info, tokenizer,
      output_attribute: :hidden_state,
      output_pool: :cls_token_pooling,
      embedding_processor: :l2_norm,
      compile: [batch_size: batch_size, sequence_length: sequence_lengths],
      defn_options: [compiler: EXLA]
    )
  end

  @doc "Embeds passages (chunk texts). Returns a list of float lists."
  def embed_passages(texts) when is_list(texts) do
    ContextArchive.Embeddings.Bulk
    |> Nx.Serving.batched_run(texts)
    |> Enum.map(&Nx.to_flat_list(&1.embedding))
  end

  @doc "Embeds one search query."
  def embed_query(text) when is_binary(text) do
    %{embedding: embedding} =
      Nx.Serving.batched_run(ContextArchive.Embeddings.Query, @query_prefix <> text)

    Nx.to_flat_list(embedding)
  end
end
