#!/usr/bin/env bash
# Install service and backup definitions after `mix setup` succeeds.
set -euo pipefail
[[ $EUID == 0 && $(hostname -s) == context-archive ]] || exit 1
repo=$(cd "$(dirname "$0")/.." && pwd)
install -d -m 0700 -o debian -g debian /srv/context-archive/raw
install -d -m 0755 -o debian -g debian /home/debian/.config/systemd/user
install -m 0644 -o debian -g debian "$repo/deploy/context-archive.service" /home/debian/.config/systemd/user/context-archive.service
install -m 0755 -o root -g root "$repo/scripts/backup-postgres.sh" /usr/local/sbin/context-archive-backup-postgres
install -d /etc/systemd/system/restic-backup.service.d
cat > /etc/systemd/system/restic-backup.service.d/context-archive.conf <<'UNIT'
[Service]
Environment=HOME=/root
ExecStartPre=/usr/local/sbin/context-archive-backup-postgres
UNIT
# Include this VM's Tailscale identity. Never edit the shared Incus profile.
python3 - <<'PY'
from pathlib import Path
p = Path('/usr/local/bin/restic-backup')
s = p.read_text()
if '/var/lib/tailscale' not in s:
    old = 'restic backup /root /home /etc /srv'
    if old not in s:
        raise SystemExit('Unexpected restic script; refusing automatic patch')
    p.write_text(s.replace(old, old + ' /var/lib/tailscale'))
PY
systemctl daemon-reload
loginctl enable-linger debian
systemctl start user@1000.service
runuser -u debian -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload
runuser -u debian -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user enable --now context-archive.service
