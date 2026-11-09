#!/usr/bin/env python3
"""Build the OpenAPI document an agent tool gateway imports, from the one AshJsonApi generates.

    export CONTEXT_ARCHIVE_URL=https://context-archive.<tailnet>.ts.net
    curl -s -H "Authorization: Bearer $(cat ~/.config/context-archive/read.token)" \
      "$CONTEXT_ARCHIVE_URL/api/open_api" \
      | python3 scripts/build-openapi.py > openapi/context-archive.openapi.json

The document's server is $CONTEXT_ARCHIVE_URL (the committed copy keeps the
placeholder; build with your real URL before importing it into your gateway).

Normalizes for tool gateways: stable operation ids and one tag (tools become
`archive.search`, `archive.readDocument`, `archive.chunkContext`, `archive.status`),
a bearer-token security scheme described as a Context Archive read token, and no
`unmasked` option (admin-only; a gateway never holds an admin token).
"""
import json
import os
import sys

SERVER = os.environ.get("CONTEXT_ARCHIVE_URL", "https://context-archive.<tailnet>.ts.net")
OPERATIONS = {
    ("post", "/api/v1/search"): ("search", "Search archived context (hybrid, keyword or vector)"),
    ("post", "/api/v1/find"): ("find", "Passages judged to answer a question, fused across search phrasings"),
    ("get", "/api/v1/documents/{document}"): ("readDocument", "Read a document (Pi session) in file order"),
    ("get", "/api/v1/chunks/{chunk_id}/context"): ("chunkContext", "Records before and after a search hit"),
    ("get", "/api/v1/status"): ("status", "Freshness, backlog and embedding coverage"),
}

spec = json.load(sys.stdin)
spec["info"] = {
    "title": "Context Archive",
    "version": spec.get("info", {}).get("version", "1.0.0"),
    "description": (
        "Archive of agent sessions across machines. Find fuses several search phrasings into "
        "paginated passages, judged relevant by a judge model when one is configured. Only "
        "masked agents-scope text is sent to the judge; failed or excluded judgments remain "
        "explicitly unjudged. "
        "Search returns ranked candidates with provenance. Text is masked for secrets."
    ),
}
spec["servers"] = [{"url": SERVER}]
spec["tags"] = [{"name": "archive", "description": "Search and read archived context"}]
spec.setdefault("components", {})["securitySchemes"] = {
    "bearerAuth": {"type": "http", "scheme": "bearer", "description": "Context Archive read token"}
}
spec["security"] = [{"bearerAuth": []}]

for (method, path), (op_id, summary) in OPERATIONS.items():
    op = spec["paths"][path][method]
    op["operationId"] = op_id
    op["summary"] = summary
    op["tags"] = ["archive"]
    op["parameters"] = [p for p in op.get("parameters", []) if p.get("name") != "unmasked"]
    body = op.get("requestBody", {}).get("content", {})
    for media in body.values():
        props = media.get("schema", {}).get("properties", {}).get("data", {}).get("properties", {})
        props.pop("unmasked", None)

unknown = {(m, p) for p, ops in spec["paths"].items() for m in ops} - set(OPERATIONS)
if unknown:
    sys.exit(f"unmapped operations: {sorted(unknown)}")

json.dump(spec, sys.stdout, indent=2, sort_keys=False)
sys.stdout.write("\n")
