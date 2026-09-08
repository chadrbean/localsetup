#!/usr/bin/env bash
# Install USER-level systemd unit for the gateway (no sudo needed; linger is
# already enabled so it starts at boot). Also enables the user podman service
# so the litellm-db container (--restart=always) comes back.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR"
cp systemd/localsetup-gateway.service "$UNIT_DIR/"

systemctl --user daemon-reload
systemctl --user enable --now localsetup-gateway

# podman restart policy for litellm-db at boot
systemctl --user enable podman.service >/dev/null 2>&1 || true

echo "== status =="
systemctl --user --no-pager status localsetup-gateway --lines=2 | head-6
echo
echo "logs:  journalctl --user -u localsetup-gateway -f"
