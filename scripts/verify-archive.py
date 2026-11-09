#!/usr/bin/env python3
"""Verify that a machine's archived streams are byte-identical to its local files.

Run on the machine that shipped the files. Reads the VM's listing (produced on the VM by
`scripts/list-streams.sh <machine>`: kind, mode, path, generation, bytes, sha256 per
latest generation) from stdin and compares each against sha256 of the same number of
leading bytes of the local file. Prints counts and mismatching paths only.

The shipper redacts credential shapes before upload (length-preserving), so the local
bytes are redacted the same way before hashing. Streams archived before redaction
still hold the raw bytes; those count as `match_unredacted` (legacy), not mismatches.
An append stream that held a token and kept growing across the switch is raw up to
some line and redacted after it; each possible switch point (just before a line the
redaction changes) is tried, and a hit counts as `match_mixed`. Anything else is a mismatch.

  ssh context-archive 'bash context-archive/scripts/list-streams.sh mini' \
    | python3 scripts/verify-archive.py ~/.config/context-archive/shipper.json

Opt-in --full-file uses explicit --candidates instead of shipper roots, requires
full EOF inclusion, and writes private JSON receipts under --receipts-dir.
Receipts are CONTENT-INCLUSION ONLY, never deletion certificates.
"""
import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "shipper"))
from context_archive_shipper import redact  # noqa: E402


def expand(p):
    return Path(os.path.expandvars(os.path.expanduser(p)))


def file_hashes(f, n, max_line=None):
    """Hash up to n bytes, including a final fragment. Return both hashes and count.

    The shipper's redaction never crosses a newline, so whole lines are safe units.
    """
    raw, red = hashlib.sha256(), hashlib.sha256()
    remaining = n
    while remaining:
        line = f.readline(min(remaining, max_line + 1) if max_line else remaining)
        if not line:
            break
        if max_line and len(line) > max_line:
            raise ValueError("line_too_large_for_full_file_verification")
        masked = redact(line)
        if len(masked) != len(line):
            raise ValueError("redaction_changed_length")
        raw.update(line)
        red.update(masked)
        remaining -= len(line)
    return raw.hexdigest(), red.hexdigest(), n - remaining


def prefix_sha256(path, n):
    """(raw, redacted) hashes of the first n bytes, or None if shorter."""
    with open(path, "rb") as f:
        raw, red, count = file_hashes(f, n)
    return (raw, red) if count == n else (None, None)


def mixed_match(path, n, sha, limit=64):
    """True/False, or None when there are too many switch points to try. True if the first n bytes equal raw lines up to some switch point and redacted
    lines after it. Only lines that redaction changes can tell the two apart, so the
    candidates are: switch just before the 1st, 2nd, ... changed line."""
    changed = []  # line numbers whose redaction differs
    with open(path, "rb") as f:
        remaining, i = n, 0
        while remaining:
            line = f.readline(remaining)
            if not line:
                return False
            if redact(line) != line:
                changed.append(i)
            remaining -= len(line)
            i += 1
    if not changed:
        return False
    if len(changed) > limit:
        return None  # too many candidates to try: unverified, not a proven mismatch
    for switch in changed[1:]:  # before changed[0] = all redacted, after the last = all raw: checked already
        h = hashlib.sha256()
        with open(path, "rb") as f:
            remaining, i = n, 0
            while remaining:
                line = f.readline(remaining)
                if not line:
                    return False  # the file shrank since the first pass
                h.update(line if i < switch else redact(line))
                remaining -= len(line)
                i += 1
        if h.hexdigest() == sha:
            return True
    return False


def text_field(value):
    return (isinstance(value, str) and bool(value)
            and not any(ord(c) < 32 or ord(c) == 127 for c in value))


def relative_path(value):
    return text_field(value) and all(part not in ("", ".", "..") for part in value.split("/"))


def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_candidate_json_key")
        result[key] = value
    return result


def load_candidates(path):
    try:
        candidates = json.loads(Path(path).read_text(), object_pairs_hook=unique_json_object)
    except (OSError, UnicodeError, ValueError):
        raise ValueError("candidate_manifest_unreadable_or_malformed") from None
    if not isinstance(candidates, list) or not candidates:
        raise ValueError("candidate_manifest_must_be_a_nonempty_array")
    stream_keys, local_paths = set(), set()
    for candidate in candidates:
        if (not isinstance(candidate, dict)
                or set(candidate) != {"kind", "path", "local_path"}
                or not text_field(candidate["kind"])
                or not relative_path(candidate["path"])
                or not text_field(candidate["local_path"])
                or not Path(candidate["local_path"]).is_absolute()):
            raise ValueError("malformed_candidate_fields")
        key = (candidate["kind"], candidate["path"])
        local = os.path.normpath(candidate["local_path"])
        if key in stream_keys or local in local_paths:
            raise ValueError("duplicate_candidate_identity")
        stream_keys.add(key)
        local_paths.add(local)
    return candidates


def load_streams(lines):
    streams = {}
    for line in lines:
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 6:
            raise ValueError("malformed_server_row")
        kind, mode, path, generation, size, sha = fields
        if (not text_field(kind) or mode not in ("append", "snapshot")
                or not relative_path(path)
                or not re.fullmatch(r"[0-9]+", generation)
                or not re.fullmatch(r"[0-9]+", size)
                or not re.fullmatch(r"[0-9a-fA-F]{64}", sha)):
            raise ValueError("malformed_server_row")
        try:
            generation, size = int(generation), int(size)
        except ValueError:
            raise ValueError("malformed_server_row") from None
        streams.setdefault((kind, path), []).append({
            "kind": kind, "path": path, "mode": mode,
            "generation": generation, "bytes_received": size,
            "sha256": sha.lower(),
        })
    if not streams:
        raise ValueError("empty_server_manifest")
    return streams


def file_identity(info):
    return {"device": info.st_dev, "inode": info.st_ino, "size": info.st_size,
            "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns}


def hash_candidate(candidate, receipt):
    """Check path and descriptor identity around a bounded full read and EOF probe."""
    path = Path(candidate["local_path"])
    before = path.lstat()
    receipt["identity_before"] = file_identity(before)
    receipt["local_size"] = before.st_size
    if stat.S_ISLNK(before.st_mode):
        return "symlink_rejected_use_explicit_resolved_path"
    if not stat.S_ISREG(before.st_mode):
        return "local_path_is_not_a_regular_file"
    resolved = path.resolve(strict=True)
    receipt["resolved_path"] = str(resolved)
    # NOFOLLOW rejects a leaf swapped to a symlink; NONBLOCK avoids hanging on a
    # leaf swapped to a FIFO. Parent resolution is checked again after reading.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        opened = os.fstat(f.fileno())
        if not stat.S_ISREG(opened.st_mode) or file_identity(opened) != file_identity(before):
            return "local_identity_changed_before_hashing"
        raw, red, count = file_hashes(f, before.st_size, max_line=8 * 1024 * 1024)
        eof = not f.read(1)
        after = os.fstat(f.fileno())
    receipt.update({"original_sha256": raw, "redacted_sha256": red,
                    "bytes_hashed": count,
                    "identity_after": file_identity(after)})
    if (file_identity(before) != file_identity(after)
            or file_identity(before) != file_identity(path.lstat())
            or path.resolve(strict=True) != resolved
            or count != before.st_size or not eof):
        return "local_file_unstable_during_hashing"
    receipt["full_hashes_complete"] = True
    return None


def verify_candidate(candidate, streams, server_failure):
    matches = streams.get((candidate["kind"], candidate["path"]), [])
    receipt = {
        "scope": "CONTENT-INCLUSION ONLY",
        "limitations": "Not a deletion certificate. No backup, parsing or local-consumer promise.",
        "candidate": candidate, "input_path": candidate["local_path"],
        "resolved_path": None, "identity_before": None, "identity_after": None,
        "streams": matches, "local_size": None, "bytes_hashed": 0,
        "original_sha256": None, "redacted_sha256": None,
        "full_hashes_complete": False, "status": "failed", "classification": "unverified",
        "exact_original_preserved": False, "failure_reason": None,
    }
    try:
        failure = hash_candidate(candidate, receipt)
    except FileNotFoundError:
        failure = "local_file_missing_or_disappeared"
    except (OSError, RuntimeError):
        failure = "local_file_unreadable_or_path_changed"
    except ValueError as error:
        failure = (str(error) if str(error) in (
            "redaction_changed_length", "line_too_large_for_full_file_verification"
        ) else "local_hash_unverified")
    if not failure:
        if server_failure:
            failure = server_failure
        elif not matches:
            failure = "missing_server_entry"
        elif len(matches) != 1:
            failure = "ambiguous_server_matches"
        elif receipt["local_size"] != matches[0]["bytes_received"]:
            failure = "local_size_differs_from_committed_size"
        elif receipt["original_sha256"] == matches[0]["sha256"]:
            receipt.update(classification="exact", exact_original_preserved=True)
        elif receipt["redacted_sha256"] == matches[0]["sha256"]:
            receipt["classification"] = "redacted"
        elif (matches[0]["mode"] == "append"
              and receipt["original_sha256"] != receipt["redacted_sha256"]):
            receipt["classification"] = "mixed_unverified"
            failure = "hash_mismatch_possible_legacy_mixed_redaction"
        else:
            failure = "full_file_hash_mismatch"
    receipt["failure_reason"] = failure
    receipt["status"] = "failed" if failure else "verified"
    return receipt


def verify_full(candidates_path, receipts_path):
    candidates = load_candidates(candidates_path)
    try:
        streams, server_failure = load_streams(sys.stdin), None
    except UnicodeError:
        streams, server_failure = {}, "server_manifest_unreadable"
    except ValueError as error:
        streams, server_failure = {}, str(error)
    except OSError:
        streams, server_failure = {}, "server_manifest_unreadable"
    # Anchor creation/open to a private parent, not a replaceable public path.
    destination = Path(receipts_path)
    if destination.name in ("", ".", ".."):
        raise ValueError("invalid_receipt_directory_name")
    parent = os.open(destination.parent.resolve(strict=True),
                     os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parent_info = os.fstat(parent)
        if parent_info.st_uid != os.getuid() or stat.S_IMODE(parent_info.st_mode) & 0o077:
            raise ValueError("receipt_parent_must_be_owned_and_private")
        os.mkdir(destination.name, 0o700, dir_fd=parent)
        created = os.stat(destination.name, dir_fd=parent, follow_symlinks=False)
        directory = os.open(destination.name,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        opened = os.fstat(directory)
        if (opened.st_dev, opened.st_ino) != (created.st_dev, created.st_ino) or (
                opened.st_uid != os.getuid() or stat.S_IMODE(opened.st_mode) & 0o077):
            os.close(directory)
            raise ValueError("receipt_directory_changed_or_not_private")
    finally:
        os.close(parent)
    try:
        receipts = [verify_candidate(candidate, streams, server_failure) for candidate in candidates]
        identities = {}
        for receipt in receipts:
            before = receipt["identity_before"]
            if receipt["resolved_path"] and before:
                key = (before["device"], before["inode"])
                if key in identities:
                    for duplicate in (identities[key], receipt):
                        duplicate.update(status="failed", classification="unverified",
                                         exact_original_preserved=False,
                                         failure_reason="duplicate_resolved_local_identity")
                else:
                    identities[key] = receipt
        for index, receipt in enumerate(receipts, 1):
            fd = os.open(f"{index:06d}.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                         0o600, dir_fd=directory)
            with os.fdopen(fd, "w") as f:
                json.dump(receipt, f, indent=2)
                f.write("\n")
        failed = sum(receipt["status"] != "verified" for receipt in receipts)
        print(json.dumps({"checked": len(receipts), "verified": len(receipts) - failed,
                          "failed": failed, "scope": "CONTENT-INCLUSION ONLY"}))
        return 1 if failed else 0
    finally:
        os.close(directory)


def verify_prefix(config):
    cfg = json.loads(expand(config).read_text())
    roots = {}
    for spec in cfg["roots"]:
        roots.setdefault(spec["kind"], []).append(expand(spec["path"]))

    stats = {"checked": 0, "match": 0, "match_unredacted": 0, "match_mixed": 0, "mismatch": 0, "unverified": 0, "missing_locally": 0, "bytes": 0}
    bad = []
    unverified = []
    for line in sys.stdin:
        kind, mode, rel, generation, size, sha = line.rstrip("\n").split("\t")
        size = int(size)
        local = next((r / rel for r in roots.get(kind, []) if (r / rel).is_file()), None)
        stats["checked"] += 1
        if local is None:
            stats["missing_locally"] += 1  # e.g. purged temp files; the archive keeps them
            continue
        if mode == "append":
            raw, red = prefix_sha256(local, size)
        else:
            data = local.read_bytes()
            raw, red = hashlib.sha256(data).hexdigest(), hashlib.sha256(redact(data)).hexdigest()
        if red == sha:
            stats["match"] += 1
            stats["bytes"] += size
        elif raw == sha:
            stats["match_unredacted"] += 1
            stats["bytes"] += size
        elif mode == "append" and raw is not None and raw != red and (mm := mixed_match(local, size, sha)) is not False:
            if mm:
                stats["match_mixed"] += 1
                stats["bytes"] += size
            else:
                stats["unverified"] += 1
                unverified.append(f"{kind}:{rel} gen={generation}")
        else:
            stats["mismatch"] += 1
            bad.append(f"{kind}:{rel} gen={generation}")

    print(json.dumps(stats))
    for b in bad[:20]:
        print("mismatch:", b)
    for u in unverified[:20]:
        print("unverified (over 64 redacted lines across the switch):", u)
    return 1 if stats["mismatch"] else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("config", nargs="?", help="shipper config for legacy prefix diagnostics")
    parser.add_argument("--full-file", action="store_true", help="verify explicit candidates through EOF")
    parser.add_argument("--candidates", help="JSON array of kind, path and absolute local_path")
    parser.add_argument("--receipts-dir", help="new private directory for per-file JSON receipts")
    args = parser.parse_args()
    if args.full_file:
        if args.config or not args.candidates or not args.receipts_dir:
            parser.error("--full-file requires --candidates and --receipts-dir, without a shipper config")
        try:
            return verify_full(args.candidates, args.receipts_dir)
        except ValueError as error:
            # Only fixed validation codes escape the full-file implementation.
            print(f"full-file verification failed: {error}", file=sys.stderr)
            return 1
        except OSError:
            print("full-file verification failed: receipt_directory_or_file_unwritable; use a new directory",
                  file=sys.stderr)
            return 1
    if not args.config or args.candidates or args.receipts_dir:
        parser.error("provide a shipper config, or use --full-file with candidates and receipts")
    return verify_prefix(args.config)


if __name__ == "__main__":
    sys.exit(main())
