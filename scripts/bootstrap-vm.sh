#!/usr/bin/env bash
# Bootstrap only the dedicated, persistent Debian 13 arm64 context-archive VM.
# Run as root. Does not join Tailscale, clone a repo, or start the application.
# Pinned, checksum-verified Elixir/OTP toolchain and PostgreSQL with pgvector.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root'; exit 1; }
[[ $(hostname -s) == context-archive ]] || { echo 'Refusing a host other than context-archive'; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 && $(dpkg --print-architecture) == arm64 ]] || exit 1
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg unzip libssl3t64 libncurses6 libtinfo6 libstdc++6 build-essential inotify-tools
install -d -m 0755 /usr/share/keyrings
curl -fsSL --retry 3 https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/keyrings/postgresql.asc
printf '%s\n' 'deb [arch=arm64 signed-by=/usr/share/keyrings/postgresql.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main' > /etc/apt/sources.list.d/pgdg.list
curl -fsSL --retry 3 https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL --retry 3 https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list
apt-get update -qq
# Stable major pinned; latest security/bugfix minor. pgvector from PGDG for the same major.
apt-get install -y -qq postgresql-18 postgresql-18-pgvector tailscale
printf "listen_addresses = '127.0.0.1'\n" > /etc/postgresql/18/main/conf.d/context-archive.conf
systemctl enable --now postgresql tailscaled
systemctl restart postgresql@18-main
# App user is not a superuser. Peer authentication works only as Unix user debian.
if ! runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='debian'" | grep -qx 1; then
  runuser -u postgres -- createuser --createdb --no-superuser --no-createrole debian
fi
# pgvector is a trusted extension only for superusers by default; create it in template1
# so every database the app creates (dev and test) already has it.
runuser -u postgres -- psql -d template1 -Atqc 'CREATE EXTENSION IF NOT EXISTS vector'

# Hex's Ubuntu 24.04 ARM64 OTP build: validated on Debian 13 by the checks below.
# SHA256 from https://builds.hex.pm/builds/otp/arm64/ubuntu-24.04/builds.txt.
otp=/opt/context-archive/otp-29.1.2
elixir=/opt/context-archive/elixir-1.20.4-otp-29
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
if [[ ! -x $otp/bin/erl ]]; then
  curl -fsSL --retry 3 https://builds.hex.pm/builds/otp/arm64/ubuntu-24.04/OTP-29.1.2.tar.gz -o "$scratch/otp.tar.gz"
  echo '5d344f2ef455cfa15ad3112ce3aaecc8fa0d97532b2f106df46bc1701bc02c27  '"$scratch/otp.tar.gz" | sha256sum -c -
  install -d "$otp"
  tar xzf "$scratch/otp.tar.gz" --strip-components=1 -C "$otp"
  (cd "$otp" && ./Install -sasl "$otp")
fi
if [[ ! -x $elixir/bin/elixir ]]; then
  curl -fsSL --retry 3 https://github.com/elixir-lang/elixir/releases/download/v1.20.4/elixir-otp-29.zip -o "$scratch/elixir.zip"
  echo '7863c546cda13fecc949e562e326042451dacf8fd8698a36783cb71eeb223b46  '"$scratch/elixir.zip" | sha256sum -c -
  install -d "$elixir"
  unzip -q "$scratch/elixir.zip" -d "$elixir"
fi
for bin in erl erlc escript; do ln -sfn "$otp/bin/$bin" "/usr/local/bin/$bin"; done
for bin in elixir elixirc iex mix; do ln -sfn "$elixir/bin/$bin" "/usr/local/bin/$bin"; done
export PATH="$elixir/bin:$otp/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
elixir --version
elixir -e ':ok = Application.ensure_started(:crypto); :ok = Application.ensure_started(:asn1); :ok = Application.ensure_started(:public_key); :ok = Application.ensure_started(:ssl); IO.puts("OTP crypto/TLS OK")'
runuser -u postgres -- psql -Atqc 'SHOW server_version'
runuser -u postgres -- psql -d template1 -Atqc "SELECT extversion FROM pg_extension WHERE extname = 'vector'"

# Runtime key stays out of Git, command arguments and logs.
install -d -m 0700 -o debian -g debian /home/debian/.config/context-archive
if [[ ! -f /home/debian/.config/context-archive/secret_key_base ]]; then
  python3 - <<'PY'
import os, secrets
p = '/home/debian/.config/context-archive/secret_key_base'
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write(secrets.token_urlsafe(64))
os.chown(p, 1000, 1000)
PY
fi
# Raw archive (byte-exact, append-only) and logical DB dumps, both under the /srv backup scope.
install -d -m 0700 -o debian -g debian /srv/context-archive /srv/context-archive/raw
install -d -m 0700 /srv/context-archive/backups
loginctl enable-linger debian
systemctl start user@1000.service
# Login sessions and the service use the same peer-authenticated DB connection.
if ! grep -q '^export CONTEXT_ARCHIVE_LOCAL_DB=1$' /home/debian/.profile; then
  printf '\nexport CONTEXT_ARCHIVE_LOCAL_DB=1\n' >> /home/debian/.profile
fi
# The backed-up profile must have run; do not silently claim backup coverage.
test -x /usr/local/bin/restic-backup
systemctl enable --now restic-backup.timer
printf '%s\n' 'VM bootstrap complete; app, backup hook and Tailscale login still require setup.'
