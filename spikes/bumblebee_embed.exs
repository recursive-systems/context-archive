# Spike: can Bumblebee + EXLA embed on this VM (Debian 13 arm64, 2 vCPU), and how fast?
# Same 1,000 texts and model family as the fastembed benchmark (16.2 texts/s, bge-small).
# Run: elixir spikes/bumblebee_embed.exs /tmp/bench_texts.json
Mix.install(
  [
    {:bumblebee, "~> 0.6"},
    {:exla, ">= 0.0.0"},
    {:jason, "~> 1.4"}
  ],
  config: [nx: [default_backend: EXLA.Backend]]
)

[path] = System.argv()
texts = path |> File.read!() |> Jason.decode!()
repo = {:hf, "BAAI/bge-small-en-v1.5"}

{load_us, {model_info, tokenizer}} =
  :timer.tc(fn ->
    {:ok, model_info} = Bumblebee.load_model(repo)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(repo)
    {model_info, tokenizer}
  end)

IO.puts("loaded in #{Float.round(load_us / 1.0e6, 1)}s")

for seq <- [256, 512] do
  serving =
    Bumblebee.Text.text_embedding(model_info, tokenizer,
      output_attribute: :hidden_state,
      output_pool: :cls_token_pooling,
      embedding_processor: :l2_norm,
      compile: [batch_size: 16, sequence_length: seq],
      defn_options: [compiler: EXLA]
    )

  # Warm-up compiles the graph for this shape.
  {warm_us, _} = :timer.tc(fn -> Nx.Serving.run(serving, Enum.take(texts, 16)) end)

  {us, results} =
    :timer.tc(fn ->
      texts
      |> Enum.chunk_every(16)
      |> Enum.flat_map(fn batch -> Nx.Serving.run(serving, batch) end)
    end)

  %{embedding: first} = hd(results)

  IO.puts(
    "seq=#{seq} compile+first_batch=#{Float.round(warm_us / 1.0e6, 1)}s " <>
      "texts/s=#{Float.round(length(texts) / (us / 1.0e6), 1)} dims=#{Nx.size(first)} " <>
      "norm=#{first |> Nx.pow(2) |> Nx.sum() |> Nx.sqrt() |> Nx.to_number() |> Float.round(3)}"
  )
end
