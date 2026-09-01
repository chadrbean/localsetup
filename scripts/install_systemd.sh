#!/usr/bin/env bash
# Install USER-level systemd units for gateway + router (no sudo needed;
# linger is already enabled so they start at boot). Also enables the user
# podman service so the litellm-db container (--restart=always) comes back.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR"
cp systemd/llmlocalsetup-gateway.service "$UNIT_DIR/"
cp systemd/llmlocalsetup-router.service "$UNIT_DIR/"

systemctl --user daemon-reload
systemctl --user enable --now llmlocalsetup-gateway llmlocalsetup-router

# podman restart policy for litellm-db at boot
systemctl --user enable podman.service >/dev/null 2>&1 || true

echo "== status =="
systemctl --user --no-pager status llmlocalsetup-gateway --lines=2 | head -6
systemctl --user --no-pager status llmlocalsetup-router --lines=2 | head -6
echo
echo "logs:  journalctl --user -u llmlocalsetup-gateway -f"
