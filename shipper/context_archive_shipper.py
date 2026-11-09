#!/usr/bin/env python3
"""Context Archive shipper: push new bytes of local files to the archive.

Stdlib only (Python 3.9+), so it runs unchanged on macOS and Linux
machines. One run = one pass; a LaunchAgent or systemd user timer repeats it.

Two modes per root:
  append    JSONL files that only grow (Pi sessions). Only complete lines are
            sent, from the offset the server already holds.
  snapshot  small files rewritten in place (pi-subagents run status). The whole
            file is sent whenever its content hash changes.

The server is the authority on what it holds. A file whose first bytes changed,
or that shrank below the archived offset, starts a new *generation* at byte 0;
earlier bytes are never overwritten on the server.

Config: ~/.config/context-archive/shipper.json (mode 0600), for example
  {"url": "https://context-archive.<tailnet>.ts.net",
   "source": "mini",
   "token_file": "~/.config/context-archive/ingest.token",
   "roots": [{"kind": "pi-sessions", "path": "~/.pi/agent/sessions", "mode": "append", "glob": "**/*.jsonl"}]}
A root may also name `exclude_dirs` (path parts to skip) and `since` ("YYYY-MM-DD"):
files last modified before that date are skipped, so a machine can start shipping a
large history from a date on (a file modified later is shipped whole then).
Prints only counts and paths relative to their root, never file content or the token.

Redaction: known credential shapes (GitHub, sk- provider keys, Linear,
Fireworks, Slack, Telegram bot tokens, RESTIC_PASSWORD=) are masked before any
byte leaves the machine. Masks keep the length (prefix kept, the rest '*'), so
offsets, line boundaries and the head hash stay consistent between runs. No
pattern crosses a newline, so redacting whole lines equals redacting the file.
Text kept as a JSON array of byte values (the Grok CLI stores bash output so,
"output":[104,105,...]) is decoded and masked the same way: each masked byte's
number becomes 42 ('*'), padded with spaces to its width, so the length and the
JSON hold too.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HEAD_BYTES = 4096            # identity of a file's beginning, to detect rewrites
MAX_BATCH = 8 * 1024 * 1024  # bytes per request (a single longer line is sent whole)
TIMEOUT = 60
USER_AGENT = "context-archive-shipper/1"


# Every pattern starts with a literal so the scan is fast; the left boundary is
# checked in code: not inside a longer word or a base64/base64url blob (the
# encrypted_content blobs in transcripts contain fw_/sk- lookalikes), except right
# after a JSON escape (\\n, \\t, \\r), where a line of tool output starts.
_RESTIC = rb"(RESTIC_PASSWORD(?:\\?[\"'])?[ \t]*[=:][ \t]*"
REDACTIONS = [
    # (name, pattern: group 1 = kept prefix, group 2 = masked secret)
    ("github", rb"(gh[pousr]_)([A-Za-z0-9]{30,251})(?![A-Za-z0-9_])"),
    ("github-pat", rb"(github_pat_)([A-Za-z0-9_]{22,251})(?![A-Za-z0-9_])"),
    ("sk", rb"(sk-)([A-Za-z0-9_-]{20,250})(?![A-Za-z0-9_-])"),
    ("linear", rb"(lin_(?:api|oauth)_)([A-Za-z0-9]{20,250})(?![A-Za-z0-9_])"),
    ("fireworks", rb"(fw_)([A-Za-z0-9]{20,250})(?![A-Za-z0-9_])"),
    ("slack", rb"(xox[abposr]-)([A-Za-z0-9-]{10,250})(?![A-Za-z0-9-])"),
    # Telegram bot token <8-10 digit bot id>:<35 chars>; the id is checked in code.
    ("telegram-bot", rb"(:)([A-Za-z0-9_-]{35})(?![A-Za-z0-9_-])"),
    # RESTIC_PASSWORD= / "RESTIC_PASSWORD": in its quoted forms first (the value may hold
    # spaces or JSON escapes; the closing quote stays), then the bare shell form.
    # Inside a JSON string (\"...\"), read shell-level units so that only a real closing
    # quote ends the value: a shell escape (JSON \\ plus the next JSON unit, e.g. \\\" for
    # an escaped quote), or any other JSON unit except \\ and \". The units are disjoint,
    # so backtracking cannot find an earlier "closing" quote inside the value.
    ("restic-password", _RESTIC + rb'\\")((?:\\\\(?:\\[^\n]|[^\\\n])|\\[^"\\\n]|[^\\\n]){1,512}?)(?=\\")'),
    # Raw double quotes (shell text, or a raw JSON value): \x escapes do not close.
    ("restic-password", _RESTIC + rb'")((?:\\[^\n]|[^"\\\n]){1,512}?)(?=")'),
    ("restic-password", _RESTIC + rb"')([^'\n]{1,512}?)(?=')"),
    ("restic-password", _RESTIC + rb")([^\s\"'\\]{1,512})"),
]
_REDACT_RE = [(name, re.compile(p)) for name, p in REDACTIONS]
_WORD = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+/-")
_DIGITS = frozenset(b"0123456789")
# Longest match: a restic value of 512 shell-level units of up to 4 bytes each (a JSON-escaped
# shell escape), plus its prefix and the 2-byte closing quote the lookahead needs. The head
# window reads this much past HEAD_BYTES so a match straddling it is decided exactly as on
# the full line.
MAX_MATCH = 512 * 4 + 2 + 64
# In a byte array a byte takes up to 5 bytes ("255, "), so a match there spans up to 5 * MAX_MATCH.
HEAD_SLACK = 5 * MAX_MATCH
# A run of at least 8 byte values in a JSON array: numbers separated by commas (and a space).
_BYTE_RUN = re.compile(rb"(?<![\w.])(?:\d{1,3}, ?){7,}\d{1,3}(?![\w.])")
_NUMBER = re.compile(rb"\d+")


def _left_ok(s: bytes, i: int) -> bool:
    # "//": a token as the user of a URL, https://<token>@github.com/...
    return i == 0 or s[i - 1] not in _WORD or s[i - 2:i] in (b"\\n", b"\\t", b"\\r", b"//")


def _telegram_ok(s: bytes, colon: int) -> bool:
    i = colon
    while i > 0 and s[i - 1] in _DIGITS and colon - i < 11:
        i -= 1
    return 8 <= colon - i <= 10 and (s[i - 3:i] == b"bot" or (_left_ok(s, i) and s[i - 1:i] != b":"))


def redact(data: bytes, counts: dict | None = None) -> bytes:
    """Mask credential shapes in data, keeping its length. Never returns a secret."""
    data = _redact_text(data, counts)
    if b"," in data:
        data = _BYTE_RUN.sub(lambda m: _redact_byte_run(m.group(0), counts), data)
    return data


def _redact_byte_run(run: bytes, counts: dict | None) -> bytes:
    """A run of byte values with the bytes a mask changes in its decoded text replaced by
    42 ('*'), padded with spaces to the number's width (a one-digit value, which no shape
    but a restic password could hold, becomes 0, a byte no password holds)."""
    numbers = list(_NUMBER.finditer(run))
    values = [int(n.group(0)) for n in numbers]
    if any(v > 255 for v in values):
        return run
    decoded = bytes(values)
    masked = _redact_text(decoded, counts)
    if masked == decoded:
        return run
    out = bytearray(run)
    for n, before, after in zip(numbers, decoded, masked):
        if before != after:
            width = n.end() - n.start()
            out[n.start():n.end()] = b"42" + b" " * (width - 2) if width >= 2 else b"0"
    return bytes(out)


def _redact_text(data: bytes, counts: dict | None = None) -> bytes:
    for name, rx in _REDACT_RE:
        def mask(m, name=name):
            if name == "telegram-bot":
                if not _telegram_ok(m.string, m.start()):
                    return m.group(0)
            elif name != "restic-password" and not _left_ok(m.string, m.start()):
                return m.group(0)
            if counts is not None:
                counts[name] = counts.get(name, 0) + 1
            return m.group(1) + b"*" * len(m.group(2))
        data = rx.sub(mask, data)
    return data


def redacted_head(fh, limit: int) -> bytes:
    """The first `limit` bytes of the file as they are archived (redacted)."""
    fh.seek(0)
    return redact(fh.read(limit + HEAD_SLACK))[:limit]


def expand(p: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(p)))


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Client:
    def __init__(self, url: str, token: str, source: str):
        self.url = url.rstrip("/")
        self.token = token
        self.source = source

    def _request(self, method: str, path: str, body: bytes | None = None, headers: dict | None = None):
        h = {"Authorization": f"Bearer {self.token}", "User-Agent": USER_AGENT, "Connection": "close"}
        h.update(headers or {})
        req = urllib.request.Request(self.url + path, data=body, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            try:
                payload = json.loads(e.read() or b"{}")
            except Exception:  # unreadable or truncated error body (e.g. proxy 502)
                payload = {}
            return e.code, payload

    def state(self, kind: str) -> dict:
        status, body = self._request("GET", f"/ingest/v1/sources/{self.source}/streams?kind={kind}")
        if status != 200:
            raise RuntimeError(f"state request failed: HTTP {status} {body.get('error', '')}")
        # {path: {"generation": int, "offset": int, "head_sha256": str|None, "content_sha256": str|None}}
        return body.get("streams", {})

    def append(self, kind: str, mode: str, rel: str, generation: int, offset: int, data: bytes, head: str):
        headers = {
            "Content-Type": "application/octet-stream",
            "Content-Encoding": "gzip",
            "X-Archive-Kind": kind,
            "X-Archive-Mode": mode,
            "X-Archive-Path": rel,
            "X-Archive-Generation": str(generation),
            "X-Archive-Offset": str(offset),
            "X-Archive-Length": str(len(data)),
            "X-Archive-Sha256": sha256(data),
            "X-Archive-Head-Sha256": head,
        }
        return self._request("POST", f"/ingest/v1/sources/{self.source}/append", gzip.compress(data, 6), headers)


def complete_prefix(data: bytes) -> int:
    """Length of the prefix of data that ends in a newline (0 if none)."""
    i = data.rfind(b"\n")
    return i + 1


def ship_append(client: Client, kind: str, root: Path, path: Path, known: dict, stats: dict):
    rel = path.relative_to(root).as_posix()
    size = path.stat().st_size
    with path.open("rb") as fh:
        entry = known.get(rel)
        generation, offset = (entry["generation"], entry["offset"]) if entry else (0, 0)
        if entry and offset > 0:
            # The server hashes the first min(HEAD_BYTES, offset) bytes it holds for
            # this generation. A local file that shrank below that offset, or whose
            # same prefix now hashes differently, was rewritten: archive it anew.
            # Both sides are redacted bytes; a file archived before redaction whose
            # head held a token starts a new (redacted) generation once.
            local_prefix = sha256(redacted_head(fh, min(HEAD_BYTES, offset)))
            if size < offset or local_prefix != entry.get("head_sha256"):
                generation, offset = generation + 1, 0
                stats["new_generations"] += 1
        head = sha256(redacted_head(fh, min(HEAD_BYTES, size)))
        while offset < size:
            fh.seek(offset)
            chunk = fh.read(MAX_BATCH)
            n = complete_prefix(chunk)
            if n == 0:
                # One line longer than MAX_BATCH, or an incomplete last line.
                rest = fh.read()
                full = chunk + rest
                n = complete_prefix(full)
                if n == 0:
                    return  # the writer has not finished this line yet
                chunk = full
            data = redact(chunk[:n], stats["redactions"])
            status, body = client.append(kind, "append", rel, generation, offset, data, head)
            if status == 409 and "offset" in body:
                # Server holds a different offset (another run, or a lost reply): resync.
                generation, offset = body.get("generation", generation), body["offset"]
                stats["resyncs"] += 1
                if stats["resyncs"] > 100:
                    raise RuntimeError("too many resyncs; stopping this run")
                continue
            if status >= 500:
                raise urllib.error.URLError(f"server unavailable (HTTP {status}); retry next run")
            if status != 200:
                raise RuntimeError(f"append {rel} failed: HTTP {status} {body.get('error', '')}")
            offset = body["offset"]
            stats["bytes"] += len(data)
            stats["batches"] += 1


def ship_snapshot(client: Client, kind: str, root: Path, path: Path, known: dict, stats: dict):
    rel = path.relative_to(root).as_posix()
    data = redact(path.read_bytes(), stats["redactions"])
    digest = sha256(data)
    entry = known.get(rel)
    if entry and entry.get("content_sha256") == digest:
        return
    generation = entry["generation"] + 1 if entry else 0
    status, body = client.append(kind, "snapshot", rel, generation, 0, data, sha256(data[:HEAD_BYTES]))
    if status == 409:
        stats["resyncs"] += 1
        return  # picked up next run with fresh server state
    if status != 200:
        raise RuntimeError(f"snapshot {rel} failed: HTTP {status} {body.get('error', '')}")
    stats["bytes"] += len(data)
    stats["batches"] += 1


def run(config_path: Path, dry_run: bool) -> int:
    cfg = json.loads(config_path.read_text())
    token = expand(cfg["token_file"]).read_text().strip()
    client = Client(cfg["url"], token, cfg["source"])
    stats = {"files": 0, "bytes": 0, "batches": 0, "new_generations": 0, "resyncs": 0, "errors": 0,
             "redactions": {}}
    started = time.time()
    for spec in cfg["roots"]:
        since = time.mktime(time.strptime(spec["since"], "%Y-%m-%d")) if spec.get("since") else None
        root = expand(spec["path"])
        if not root.is_dir():
            continue
        kind, mode = spec["kind"], spec.get("mode", "append")
        known = {} if dry_run else client.state(kind)
        for path in sorted(root.glob(spec.get("glob", "**/*.jsonl"))):
            if not path.is_file() or any(part in spec.get("exclude_dirs", []) for part in path.relative_to(root).parts):
                continue
            if since is not None and path.stat().st_mtime < since:
                continue
            stats["files"] += 1
            if dry_run:
                continue
            try:
                (ship_append if mode == "append" else ship_snapshot)(client, kind, root, path, known, stats)
            except (OSError, RuntimeError, urllib.error.URLError) as e:
                stats["errors"] += 1
                print(f"error: {kind}:{path.relative_to(root).as_posix()}: {e}", file=sys.stderr)
                if isinstance(e, urllib.error.URLError):
                    break  # server unreachable: stop this root, retry next run
    stats["seconds"] = round(time.time() - started, 1)
    print(json.dumps(stats))
    return 1 if stats["errors"] else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--config", default="~/.config/context-archive/shipper.json")
    ap.add_argument("--dry-run", action="store_true", help="list what would be considered; send nothing")
    args = ap.parse_args()
    return run(expand(args.config), args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
