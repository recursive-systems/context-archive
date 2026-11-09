#!/usr/bin/env bash
# Use the actual joined node identity; never enable Funnel or Tailscale SSH.
set -euo pipefail
[[ $EUID == 0 && $(hostname -s) == context-archive ]] || exit 1
host=$(tailscale status --json | python3 -c '
import json, sys
s = json.load(sys.stdin)
if s.get("BackendState") != "Running":
    raise SystemExit("Join Tailscale first")
print(s["Self"]["DNSName"].rstrip("."))
')
[[ $host =~ ^[a-zA-Z0-9.-]+\.ts\.net$ ]] || { echo 'Unexpected DNS name'; exit 1; }
install -d -m 0700 -o debian -g debian /home/debian/.config/context-archive
umask 077
printf 'PHX_HOST=%s\n' "$host" > /home/debian/.config/context-archive/service.env
chown debian:debian /home/debian/.config/context-archive/service.env
runuser -u debian -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart context-archive.service
tailscale serve --bg http://127.0.0.1:4000
printf 'Private URL: https://%s\n' "$host"
