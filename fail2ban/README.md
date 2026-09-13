# fail2ban/ — OS-level SSH brute-force protection (native install, not a container)

**Native `apt install fail2ban` on the host, running as root under systemd.**
The config here is the tracked source of truth; `jail.d/sshd.conf` is
manually copied to `/etc/fail2ban/jail.d/` (see Install below) — there is
no live symlink, so re-copy after editing.

## Why native, not a container (tried, reverted)

Two dead ends, in order, worth remembering before re-attempting this:

1. **Rootless podman can't read the host journal.** journald files are
   group-owned `systemd-journal` (GID 999) on the host; rootless podman
   maps container-root to your host UID/GID (1000), which has no mapping
   for GID 999 (outside the subordinate-GID range and not one of your
   supplementary groups). The container silently saw 0 journal entries —
   no error, just an empty filter.
2. **Even with journal access fixed, rootless can't ban.** `NET_ADMIN`/
   `NET_RAW` capabilities are scoped to the user namespace that owns the
   target network namespace. `network_mode: host` shares the REAL host
   netns, which belongs to the initial (root) user namespace — a rootless
   container's capabilities don't carry authority there, so firewall
   rule inserts would fail even after granting the container every
   plausible capability.

Both are structural, not config bugs — a container only works here as
**rootful podman** (`sudo podman ...`), which is a different lifecycle
from every other container in this repo (all rootless as `chad`) for no
real benefit over a native install. Native wins on simplicity.

## Why this exists (and why it's separate from traefik/'s fail2ban plugin)

sslh (public `:443`) sniffs SSH vs TLS and forwards SSH bytes **straight to
sshd on 127.0.0.1:22** — that traffic never becomes an HTTP request, so
Traefik (and its `fail2ban` middleware plugin in `../traefik/`) never sees
it and can't protect it. This is the SSH-specific counterpart:

| | `traefik/` fail2ban plugin | `fail2ban/` (this, native) |
|---|---|---|
| Protects | HTTP routes (dashboard, hermes, catch-all scans) — plus counts Grafana login 401s via the HTTP middleware | sshd (real host SSH, port 22) + Grafana logins (container journald) |
| Mechanism | In-process HTTP request counting | Tails journald, inserts nft/iptables rules |
| Runs as | Traefik container process | root, systemd (`fail2ban.service`) |

Two native jails live here (`jail.d/`):

- **sshd** — brute-force SSH via sslh (see below for the motivation).
- **grafana** — failed logins to the monitoring Grafana
  (`grafana.chadrbean.com`). Filters on the Grafana container's journald
  `method=POST path=/api/login status=401` lines
  (`CONTAINER_NAME=monitoring_grafana`), `remote_addr` = source IP.
  maxretry 5 / 10m → 1h ban, matching the traefik-plugin numbers.

Real motivating evidence: `journalctl -u ssh` on this host showed ongoing
password brute-force attempts (`Failed password for root`, invalid users)
arriving via sslh. `PasswordAuthentication no` (set in `/etc/ssh/sshd_config`)
already closes the actual vulnerability; this adds IP-level banning on top,
cutting the noise/connection churn from repeat offenders.

## Observability

`/var/log/fail2ban.log` is shipped to Loki by the **native** Promtail service
(see `../monitoring/promtail/README.md` for why it is native — same rootless-
podman-GID-mismatch reason as fail2ban itself). A Grafana dashboard is
auto-provisioned at `https://grafana.chadrbean.com/d/fail2ban` (ban rate
by jail, currently-banned counts, recent ban table). LogQL alert rules fire
on `Fail2ban Ban Spike` and `Fail2ban High Ban Rate`.

## Install / update

    sudo apt-get install -y fail2ban   # pulls python3-systemd too (journald backend)
    sudo cp jail.d/*.conf /etc/fail2ban/jail.d/
    sudo mkdir -p /etc/fail2ban/filter.d
    sudo cp filter.d/*.conf /etc/fail2ban/filter.d/   # grafana filter (only if filter.d/ exists)
    sudo systemctl restart fail2ban
    sudo systemctl status fail2ban --no-pager

Re-run the `cp` + `restart` any time a `jail.d/`/`filter.d/` file changes in this repo.
(The `sshd` jail needs no custom filter — it uses the packaged `sshd` filter.)

## Verify

    sudo fail2ban-client status sshd
    # Journal matches: _SYSTEMD_UNIT=ssh.service   <- confirms it's watching sshd
    sudo fail2ban-client status grafana
    # Journal matches: CONTAINER_NAME=monitoring_grafana

    # manual ban/unban test (proves detection -> firewall action end to end
    # without waiting for a real attacker; use a documentation/test-only IP):
    sudo fail2ban-client set sshd banip 203.0.113.55
    sudo nft list ruleset | grep -A3 f2b        # rule should appear
    sudo fail2ban-client set sshd unbanip 203.0.113.55
    sudo fail2ban-client set grafana banip 203.0.113.56   # same for the grafana jail
    sudo nft list ruleset | grep addr-set-grafana
    sudo fail2ban-client set grafana unbanip 203.0.113.56

    # live log:
    sudo tail -f /var/log/fail2ban.log

**Note on testing from localhost:** fail2ban's `ignoreself` default (on)
means it will NEVER ban 127.0.0.1 / the host's own IP, no matter how many
failed logins originate there — this is intentional (stops a jail from
locking the host out of its own network) and means local SSH-failure tests
against `127.0.0.1` (or failed Grafana logins via `curl 127.0.0.1:3000`)
will always show 0 detections. Only genuinely external
source IPs get evaluated. The `banip`/`unbanip` manual test above is the
correct way to confirm the ban mechanism works.

## Add another jail

Drop a new `.conf` into `jail.d/` (plus a `filter.d/` file if it needs a
custom regex — the filter MUST capture a `<HOST>` failure-id group, or
fail2ban refuses to start the jail), `sudo cp` it to `/etc/fail2ban/`,
`sudo systemctl restart fail2ban`.
