#!/usr/bin/env bash
# Restore the latest logical dump into a NEW disposable DB, never context_archive_dev.
set -euo pipefail
[[ $EUID == 0 && $(hostname -s) == context-archive ]] || exit 1
backup=/srv/context-archive/backups/context_archive_dev.dump
test -s "$backup"
db="context_archive_restore_verify_$$"
# create first; register cleanup only after we know this invocation owns the DB.
runuser -u postgres -- createdb --owner=debian "$db"
trap 'runuser -u postgres -- dropdb --if-exists "$db"' EXIT
# --no-comments: pgvector already exists in every new DB (created in template1, owned by
# postgres); the non-superuser restore role cannot re-comment on that extension.
runuser -u postgres -- /usr/lib/postgresql/18/bin/pg_restore \
  --exit-on-error --no-owner --no-comments --role=debian --dbname="$db" < "$backup"
versions=$(runuser -u postgres -- psql -d "$db" -Atqc 'SELECT version FROM schema_migrations ORDER BY version')
[[ -n $versions ]]
runuser -u postgres -- psql -d "$db" -Atqc 'SELECT count(*) FROM oban_jobs' >/dev/null
printf 'Backup restored successfully into disposable DB; migrations and Oban table verified.\n'
