#!/usr/bin/env bash
# Installed root-owned at /usr/local/sbin/context-archive-backup-postgres.
# A failed dump fails the restic service: never back up a stale dump as success.
# Order matters: the raw archive is append-only, so a dump taken before the file
# backup never references bytes the same snapshot lacks.
set -euo pipefail
umask 077
backup=/srv/context-archive/backups
install -d -m 0700 "$backup"
tmp=$(mktemp -d "$backup/.pending.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
runuser -u postgres -- /usr/lib/postgresql/18/bin/pg_dump -Fc context_archive_dev > "$tmp/context_archive_dev.dump"
runuser -u postgres -- /usr/lib/postgresql/18/bin/pg_dumpall --globals-only > "$tmp/globals.sql"
/usr/lib/postgresql/18/bin/pg_restore --list "$tmp/context_archive_dev.dump" >/dev/null
mv "$tmp/context_archive_dev.dump" "$backup/context_archive_dev.dump"
mv "$tmp/globals.sql" "$backup/globals.sql"
date -u +%FT%TZ > "$backup/completed_at"
