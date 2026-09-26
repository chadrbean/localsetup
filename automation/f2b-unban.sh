#!/usr/bin/env bash
# f2b-unban: unban ONE address in every fail2ban jail.
# Installed root:root 0755 at /usr/local/sbin/f2b-unban (automation/install.sh) and run as
#   sudo -u automation sudo -n /usr/local/sbin/f2b-unban <ip>
# The argument must be a single IPv4/IPv6 address: nothing else reaches fail2ban-client.
# Traefik's own ban list is in memory: clear it with `podman restart traefik` (no sudo).
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

die() { echo "f2b-unban: $*" >&2; exit 64; }

[[ $# -eq 1 ]] || die "usage: f2b-unban <ip>"
ip=$1
octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
v4="^${octet}(\\.${octet}){3}\$"
v6='^[0-9A-Fa-f:]{2,39}$'
if [[ $ip =~ $v4 ]]; then
  :
elif [[ $ip =~ $v6 && $ip == *:*:* ]]; then
  :
else
  die "not an IP address: $ip"
fi

logger -t f2b-unban -p auth.notice "unban $ip (invoked by ${SUDO_USER:-root})"
for jail in sshd grafana recidive; do
  if fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1; then
    echo "$jail: unbanned $ip"
  else
    echo "$jail: $ip was not banned"
  fi
done
