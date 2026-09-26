#!/usr/bin/env bash
# One-time Grafana Alloy install on a LAN desktop (Debian-family: PikaOS, Ubuntu).
# Runs ON the target as root. Stage it from this host, then run it with sudo:
#
#   monitoring/alloy/deploy.sh stage                            # scp to /tmp/alloy-*
#   ssh -t zuriel 'sudo bash /tmp/alloy-install.sh zuriel'      # asks for the sudo password
#
# Idempotent: re-running upgrades/downgrades to ALLOY_VERSION and re-renders the
# drop-in. Day-to-day config changes don't need this; use deploy.sh push.
set -euo pipefail

USER_NAME=${1:?usage: install.sh <desktop-user>}
VERSION=${ALLOY_VERSION:-1.20.0-1}
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
[ -d "$HOME_DIR" ] || { echo "no home for $USER_NAME" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
cd "$(dirname "$0")"

# Grafana apt repo (signed).
install -d -m 755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
apt-get update -qq
apt-mark unhold alloy >/dev/null 2>&1 || true
apt-get install -y --allow-downgrades "alloy=$VERSION"
# Pinned: upgrades are a repo change (ALLOY_VERSION here + docs/HOSTS.md).
apt-mark hold alloy

# Run as the desktop user, config + state in its home.
install -d -m 755 /etc/systemd/system/alloy.service.d
sed -e "s|@USER@|$USER_NAME|g" -e "s|@HOME@|$HOME_DIR|g" alloy-override.conf \
    > /etc/systemd/system/alloy.service.d/override.conf
install -d -o "$USER_NAME" -g "$USER_NAME" -m 755 "$HOME_DIR/.config/alloy"
install -d -o "$USER_NAME" -g "$USER_NAME" -m 700 "$HOME_DIR/.local/share/alloy"
install -o "$USER_NAME" -g "$USER_NAME" -m 644 alloy-config.alloy "$HOME_DIR/.config/alloy/config.alloy"

systemctl daemon-reload
systemctl enable alloy
systemctl restart alloy
systemctl --no-pager --lines=5 status alloy
