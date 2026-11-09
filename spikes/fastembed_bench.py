# Spike: fastembed (ONNX Runtime, dynamic shapes) on this VM, same texts as bumblebee_embed.exs.
# Run: uv run --with fastembed python spikes/fastembed_bench.py /tmp/bench_texts.json
import json
import sys
import time

from fastembed import TextEmbedding

texts = json.load(open(sys.argv[1]))
model = TextEmbedding("BAAI/bge-small-en-v1.5")
list(model.embed(texts[:8]))
for batch_size in (16, 32):
    t = time.time()
    vectors = list(model.embed(texts, batch_size=batch_size))
    dt = time.time() - t
    print(f"fastembed bge-small batch={batch_size} texts/s={len(texts) / dt:.1f} dims={len(vectors[0])}")
