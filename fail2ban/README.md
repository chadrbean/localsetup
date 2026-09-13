# fail2ban/ — OS-level SSH brute-force protection (native install, not a container)

**Native `apt install fail2ban` on the host, running as root under systemd.**
The config here is the tracked source of truth; it is manually copied to
`/etc/fail2ban/` (see Install below) — there is no live symlink, so re-copy
after editing.

```
fail2ban/
├── fail2ban.local              # server: dbpurgeage 30d (ban history for increment/recidive)
├── jail.d/
│   ├── 00-defaults.conf        # [DEFAULT] progressive-ban policy + ignoreip
│   ├── sshd.conf               # sshd jail (journald)
│   ├── grafana.conf            # Grafana login jail (container journald)
│   └── recidive.conf           # repeat offenders -> all-ports ban
├── filter.d/grafana.conf       # Grafana 401-on-/api/login regex
└── exporter/
    ├── install.sh              # installs pinned fail2ban_exporter + unit (sudo)
    └── fail2ban-exporter.service
```

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
| Protects | HTTP routes (dashboard, hermes, catch-all scans) — plus counts Grafana login 401s via the HTTP middleware | sshd (real host SSH, port 22) + Grafana logins (container journald) + repeat offenders (all ports) |
| Mechanism | In-process HTTP request counting | Tails journald / its own log, inserts nftables rules |
| Runs as | Traefik container process | root, systemd (`fail2ban.service`) |

Real motivating evidence: `journalctl -u ssh` on this host showed ongoing
password brute-force attempts (`Failed password for root`, invalid users)
arriving via sslh (~160 failures and ~35 bans/day as of 2026-09-12).
`PasswordAuthentication no` (set in `/etc/ssh/sshd_config`) already closes
the actual vulnerability; this adds IP-level banning on top, cutting the
noise/connection churn from repeat offenders.

## Ban policy

| Jail | Source | maxretry / findtime | Base bantime | Ports |
|---|---|---|---|---|
| `sshd` | journald `_SYSTEMD_UNIT=ssh.service` | 4 / 10m | 3h | ssh |
| `grafana` | journald `CONTAINER_NAME=monitoring_grafana` | 5 / 10m | 1h | http, https |
| `recidive` | `/var/log/fail2ban.log` (3 bans of one IP by any jail) | 3 / 1d | 1w | **all** |

Global (`jail.d/00-defaults.conf`):

- **`bantime.increment = true`** — each repeat ban of an IP doubles the base
  bantime (`bantime × 2^n`): sshd 3h → 6h → 12h → … capped at
  **`bantime.maxtime = 4w`**. `bantime.overalljails = true` counts prior bans
  from every jail. `bantime.rndtime = 10m` adds jitter so botnets can't time
  the unban.
- **`ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24`** — loopback + home LAN are
  never banned (plus `ignoreself`, on by default).
- **`dbpurgeage = 30d`** (`fail2ban.local`) — the Debian default of 1d wiped
  ban history daily, which silently disabled escalation and recidive.

**Grafana jail caveat:** Traefik sees every client as `127.0.0.1` (sslh is not
transparent), so Grafana's logged `remote_addr` comes from `X-Forwarded-For`,
which a client can spoof. Treat the jail as defense-in-depth; the Traefik
fail2ban plugin is the primary HTTP guard.

## Observability

End-to-end runbook (alert meanings, deploy, verify, troubleshooting):
[`../docs/SECURITY-MONITORING.md`](../docs/SECURITY-MONITORING.md).

- **Events:** `/var/log/fail2ban.log` (loglevel INFO — already has every
  `Found`/`Ban`/`Unban`/`Restore Ban` event; DEBUG adds only noise) is shipped
  to Loki by the **native** Promtail service (see
  `../monitoring/promtail/README.md`) with labels `jail`, `action`, `level`
  and the IP as structured metadata.
- **State + health:** `fail2ban-exporter` (native root service, loopback
  `:9191`, scraped by Prometheus) reads the fail2ban socket: `f2b_up`,
  `f2b_jail_count`, `f2b_jail_banned_current`, `f2b_jail_failed_current`,
  `f2b_jail_*_total`, `f2b_config_jail_{ban_time,find_time,max_retries}`,
  `f2b_errors`. It must be root (socket is `0700 root`) and is deliberately
  not bound to `fail2ban.service`, so it keeps reporting `f2b_up 0` when
  fail2ban dies.
- **Dashboard:** `https://grafana.chadrbean.com/d/fail2ban` (tracked JSON in
  `../monitoring/dashboards/fail2ban.json`): service UP/DOWN, currently
  banned, failing IPs, bans vs unbans, failures per jail, unique attacker IPs,
  top offenders, repeat offenders, jail policy table, event log, pipeline
  health.
- **Alerts (email):** `Fail2ban Service Down` (critical, 2m),
  `Fail2ban Jail Missing`, `Fail2ban Log Errors`,
  `Fail2ban Log Pipeline Silent`, `Fail2ban Ban Spike`,
  `Fail2ban High Ban Rate` — see `../monitoring/README.md#alerting`.

## Install / update

    sudo apt-get install -y fail2ban   # pulls python3-systemd too (journald backend)
    sudo cp fail2ban.local /etc/fail2ban/fail2ban.local
    sudo cp jail.d/*.conf /etc/fail2ban/jail.d/
    sudo mkdir -p /etc/fail2ban/filter.d
    sudo cp filter.d/*.conf /etc/fail2ban/filter.d/
    sudo fail2ban-client -t            # config test — fix errors BEFORE restarting
    sudo systemctl restart fail2ban
    sudo fail2ban-client status        # expect: sshd, grafana, recidive

    # exporter (first install or version bump)
    sudo ./exporter/install.sh         # prints f2b_up 1 / f2b_jail_count 3 when healthy

    # one-time: make the hostname resolve (silences "ipdns WARNING Unable to
    # find a corresponding IP address for wkspikaoschad" and lets ignoreself
    # resolve the host's own addresses)
    grep -q wkspikaoschad /etc/hosts || echo "127.0.1.1 wkspikaoschad" | sudo tee -a /etc/hosts

Re-run the `cp` + `-t` + `restart` any time a file here changes.
(The `sshd` jail needs no custom filter — it uses the packaged `sshd` filter;
`recidive` uses the packaged `recidive` filter.)

## Verify

    sudo fail2ban-client status sshd
    # Journal matches: _SYSTEMD_UNIT=ssh.service   <- confirms it's watching sshd
    sudo fail2ban-client status grafana
    # Journal matches: CONTAINER_NAME=monitoring_grafana
    sudo fail2ban-client status recidive
    sudo fail2ban-client get sshd bantime.increment   # -> true (newer clients)
    sudo fail2ban-client get dbpurgeage               # -> 2592000
    curl -s 127.0.0.1:9191/metrics | grep -E '^f2b_(up|jail_count|jail_banned_current)'

    # manual ban/unban test (proves detection -> firewall action -> dashboard
    # end to end without waiting for a real attacker; use a documentation IP):
    sudo fail2ban-client set sshd banip 203.0.113.55
    sudo nft list ruleset | grep -A3 f2b        # rule should appear
    sudo fail2ban-client set sshd unbanip 203.0.113.55
    sudo fail2ban-client set grafana banip 203.0.113.56   # same for the grafana jail
    sudo nft list ruleset | grep addr-set-grafana
    sudo fail2ban-client set grafana unbanip 203.0.113.56

    # alert test: stop fail2ban -> "Fail2ban Service Down" email within ~3m
    sudo systemctl stop fail2ban; sleep 240; sudo systemctl start fail2ban

    # live log:
    sudo tail -f /var/log/fail2ban.log

**Note on testing from localhost:** `ignoreself`/`ignoreip` mean fail2ban will
NEVER ban 127.0.0.1, the host's own IPs, or the 192.168.1.0/24 LAN, no matter
how many failed logins originate there — this is intentional (stops a jail
from locking the host out of its own network) and means local SSH-failure
tests (or failed Grafana logins via `curl 127.0.0.1:3000`) will always show
0 detections. The `banip`/`unbanip` manual test above is the correct way to
confirm the ban mechanism works.

## Add another jail

Drop a new `.conf` into `jail.d/` (plus a `filter.d/` file if it needs a
custom regex — the filter MUST capture a `<HOST>` failure-id group, or
fail2ban refuses to start the jail), `sudo cp` it to `/etc/fail2ban/`,
`sudo fail2ban-client -t`, `sudo systemctl restart fail2ban`. Then bump the
expected jail count in `../monitoring/provisioning/alerting/health-alerts.yml`
(`Fail2ban Jail Missing`, currently `< 3`).
