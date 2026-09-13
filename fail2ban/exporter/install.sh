#!/usr/bin/env bash
# Install / upgrade the fail2ban Prometheus exporter as a native root service.
#   sudo fail2ban/exporter/install.sh
# Downloads the pinned release, verifies its sha256, installs the binary to
# /usr/local/bin and the unit to /etc/systemd/system, then (re)starts it.
# To upgrade: bump VERSION + SHA256 (from the release's checksums.txt).
set -euo pipefail

VERSION="0.10.3"
SHA256="85733a343048090dba169226a8ca0b59b9cfecb9eaa163014a94146f04116e34"  # linux_amd64
BASE="https://gitlab.com/hctrdev/fail2ban-prometheus-exporter/-/releases/v${VERSION}/downloads"
TARBALL="fail2ban_exporter_${VERSION}_linux_amd64.tar.gz"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "run as root: sudo $0" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$TARBALL" "$BASE/$TARBALL"
echo "$SHA256  $tmp/$TARBALL" | sha256sum -c -
tar -xzf "$tmp/$TARBALL" -C "$tmp" fail2ban_exporter

install -m 0755 -o root -g root "$tmp/fail2ban_exporter" /usr/local/bin/fail2ban_exporter
install -m 0644 -o root -g root "$HERE/fail2ban-exporter.service" /etc/systemd/system/fail2ban-exporter.service

systemctl daemon-reload
systemctl enable fail2ban-exporter.service
systemctl restart fail2ban-exporter.service

# Wait for the listener, then show health.
for _ in $(seq 1 10); do
  if curl -fs http://127.0.0.1:9191/metrics >/dev/null; then break; fi
  sleep 1
done
systemctl --no-pager --lines=5 status fail2ban-exporter.service
curl -fs http://127.0.0.1:9191/metrics | grep -E '^f2b_(up|jail_count) '
