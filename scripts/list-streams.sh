#!/usr/bin/env bash
# On the VM, as debian: latest generation of every stream of one machine, with the
# sha256 of its raw bytes. Tab-separated: kind, mode, path, generation, bytes, sha256.
# Output feeds scripts/verify-archive.py on that machine. Prints no file content.
set -euo pipefail
machine=${1:?machine}
root=${CONTEXT_ARCHIVE_RAW_ROOT:-/srv/context-archive/raw}
# The tests point both at their own database and raw directory.
db=${CONTEXT_ARCHIVE_DB:-context_archive_dev}
psql -X -d "$db" -AtF $'\t' -v machine="$machine" <<'SQL' |
SELECT so.kind, st.mode, st.path, st.generation, st.bytes_received, st.source_id, st.id
FROM streams st
JOIN sources so ON so.id = st.source_id
WHERE so.machine = :'machine'
  AND st.generation = (SELECT max(g.generation) FROM streams g
                       WHERE g.source_id = st.source_id AND g.path = st.path)
ORDER BY so.kind, st.path;
SQL
while IFS=$'\t' read -r kind mode path generation bytes source_id stream_id; do
  sha=$(head -c "$bytes" "$root/$source_id/$stream_id.bin" | sha256sum | cut -d' ' -f1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$mode" "$path" "$generation" "$bytes" "$sha"
done
