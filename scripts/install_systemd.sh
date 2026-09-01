#!/usr/bin/env bash
# Install systemd units for the gateway + router, and ensure podman containers
# (postgres litellm-db) restart on boot.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== installing units =="
sudo cp systemd/llmlocalsetup-gateway.service /etc/systemd/system/
sudo cp systemd/llmlocalsetup-router.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now llmlocalsetup-gateway llmlocalsetup-router
echo "gateway + router enabled"

echo "== podman restart policy for litellm-db =="
if systemctl --user is-enabled podman.service >/dev/null 2>&1; then
  echo "user podman.service already enabled"
else
  echo "NOTE: enable user podman service so --restart=always containers survive boot:"
  echo "  systemctl --user enable podman.service && loginctl enable-linger $USER"
fi

echo
echo "== status =="
systemctl --no-pager status llmlocalsetup-gateway --lines=3 | head -8
systemctl --no-pager status llmlocalsetup-router --lines=3 | head -8
