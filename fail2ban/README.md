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

sslh (public `:8443`) sniffs SSH vs TLS and forwards SSH bytes **straight to
sshd on 127.0.0.1:22** — that traffic never becomes an HTTP request, so
Traefik (and its `fail2ban` middleware plugin in `../traefik/`) never sees
it and can't protect it. This is the SSH-specific counterpart:

| | `traefik/` fail2ban plugin | `fail2ban/` (this, native) |
|---|---|---|
| Protects | HTTP routes (dashboard, hermes, catch-all scans) | sshd (real host SSH, port 22) |
| Mechanism | In-process HTTP request counting | Tails journald, inserts nft/iptables rules |
| Runs as | Traefik container process | root, systemd (`fail2ban.service`) |

Real motivating evidence: `journalctl -u ssh` on this host showed ongoing
password brute-force attempts (`Failed password for root`, invalid users)
arriving via sslh. `PasswordAuthentication no` (set in `/etc/ssh/sshd_config`)
already closes the actual vulnerability; this adds IP-level banning on top,
cutting the noise/connection churn from repeat offenders.

## Install / update

    sudo apt-get install -y fail2ban   # pulls python3-systemd too (journald backend)
    sudo cp jail.d/sshd.conf /etc/fail2ban/jail.d/sshd.conf
    sudo systemctl restart fail2ban
    sudo systemctl status fail2ban --no-pager

Re-run the `cp` + `restart` any time `jail.d/sshd.conf` changes in this repo.

## Verify

    sudo fail2ban-client status sshd
    # Journal matches: _SYSTEMD_UNIT=ssh.service   <- confirms it's watching sshd

    # manual ban/unban test (proves detection -> firewall action end to end
    # without waiting for a real attacker; use a documentation/test-only IP):
    sudo fail2ban-client set sshd banip 203.0.113.55
    sudo nft list ruleset | grep -A3 f2b        # rule should appear
    sudo fail2ban-client set sshd unbanip 203.0.113.55

    # live log:
    sudo tail -f /var/log/fail2ban.log

**Note on testing from localhost:** fail2ban's `ignoreself` default (on)
means it will NEVER ban 127.0.0.1 / the host's own IP, no matter how many
failed logins originate there — this is intentional (stops a jail from
locking the host out of its own network) and means local SSH-failure tests
against `127.0.0.1` will always show 0 detections. Only genuinely external
source IPs get evaluated. The `banip`/`unbanip` manual test above is the
correct way to confirm the ban mechanism works.

## Add another jail

Drop a new `.conf` into `jail.d/`, `sudo cp` it to `/etc/fail2ban/jail.d/`,
`sudo systemctl restart fail2ban`.
