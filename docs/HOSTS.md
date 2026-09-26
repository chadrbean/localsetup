# Hosts: inventory and deployed configuration

**This repo is the configuration source for every machine it touches.** A file
that lives on a host is tracked here, installed from here, and checked for
drift from here where a check exists. Edit the repo copy, then deploy it. A
host-side edit is lost the next time the file is deployed.

## Machines

| Host | Address | Role | Access | Reports to Grafana via |
|---|---|---|---|---|
| `wkspikaoschad` (label `host="wkspikaoschad"`) | 192.168.1.30 static (+ .188 DHCP), wired | Runs every stack in this repo: Traefik, LiteLLM, monitoring (Grafana/Loki/Prometheus), Jenkins… Kopia → `s3://chadrbean-backups` | local | Promtail (native user unit, logs), `monitoring_node_exporter` container (host metrics, Prometheus job `node`), Prometheus scrapes |
| `wkspikaoszuriel` (Zuriel's workstation) | 192.168.1.35 static, Wi-Fi | Desktop. Kopia → `s3://bigpoopfart-backups`. Minecraft worlds and Mine-imator projects must stay backed up | `ssh zuriel` (user `zuriel`, key `~/.ssh/chad-localnetwork`; sudo needs its password) | Grafana Alloy 1.20 (system unit running as `zuriel`) |

Both run PikaOS 4 with KopiaUI 0.23.1 and share one Kopia config
(`kopia/README.md` → Hosts). Both machines use their real hostname as the
`host` label (`wkspikaoschad`, `wkspikaoszuriel`), so `$host` in `/d/hosts` and
`/d/kopia` lists the same two names. This machine was labelled `localsetup`
until 2026-09; old series under that label age out of Loki's 7 d retention.

SSH quirk: the desktop SSH agent refuses to sign non-interactive requests, so
scripts use `-o IdentityAgent=none -o IdentitiesOnly=yes`.

## What watches this host

| Signal | Where | Alert |
|---|---|---|
| Kopia snapshots (logs) | `/d/kopia?var-host=wkspikaoschad` | **Kopia Backup Stale**, 24 h; **Kopia Backup Warning**, 3 h |
| CPU, memory, disks, network, uptime | `/d/hosts?var-host=wkspikaoschad` (node_exporter container) | **Host disk almost full**, any real filesystem > 90% for 15 m |
| Exporter down | Prometheus target `job="node"` (`up`) | none on purpose: it's the box running Grafana |

## What watches Zuriel's workstation

| Signal | Where | Alert |
|---|---|---|
| Kopia snapshots (logs) | `/d/kopia?var-host=wkspikaoszuriel` | **Kopia Backup Stale (Zuriel)**, 72 h; per-host snapshot/S3/log error rules |
| Kopia failures (Kopia's own report) | email from `kopia@chadrbean.com` | profile `ses-email`, warning+ |
| CPU, memory, disks, network, uptime | `/d/hosts` | **Host disk almost full**, any real filesystem > 90% for 15 m |
| PC off | `/d/hosts` "Last seen" | none on purpose (desktop). A long outage shows up as Kopia staleness |

## Deployed files

| Repo path | Host → destination | Deploy | Drift / health check |
|---|---|---|---|
| `kopia/.kopiaignore` | both → `~/.kopiaignore` (hardlink here, copy on Zuriel's) | `kopia/sync-hosts.sh push` | `kopia/sync-hosts.sh check` |
| `kopia/kopia-ui-autostart.desktop` | both → `~/.config/autostart/kopia-ui.desktop` | here: `cp`; Zuriel's: `sync-hosts.sh push` | `sync-hosts.sh check` |
| `kopia/policies/*.json` | both → Kopia repository policy (not a file) | `kopia policy set …` (kopia/README.md) | `sync-hosts.sh check` (Zuriel's vs repo) |
| Kopia `ses-email` profile | both → Kopia repository (secrets from `monitoring/.env`) | here: kopia/README.md; Zuriel's: `sync-hosts.sh email` | `sync-hosts.sh check` |
| `monitoring/docker-compose.yml` (`node-exporter` service) + `monitoring/prometheus.yml` (job `node`) | here → the monitoring podman stack (read in place) | `git pull`, `cd monitoring && podman-compose up -d`, `podman restart monitoring_prometheus` | `curl -s 127.0.0.1:9100/metrics \| head -1`; Prometheus target `node` up |
| `monitoring/alloy/config.alloy` | Zuriel's → `~/.config/alloy/config.alloy` | `monitoring/alloy/deploy.sh push` (no sudo) | `monitoring/alloy/deploy.sh check` |
| `monitoring/alloy/alloy.service.d/override.conf` | Zuriel's → `/etc/systemd/system/alloy.service.d/override.conf` | `deploy.sh stage` + `install.sh` (**sudo**) | `deploy.sh check` |
| `monitoring/firewall/monitoring-lan.nft` + `.service` | here → `/etc/nftables.d/`, `/etc/systemd/system/` | **sudo**, `monitoring/firewall/README.md` | `sudo nft list table inet monitoring_lan`; `deploy.sh check` (pushes arrive) |
| `monitoring/promtail/promtail.service` | here → `~/.config/systemd/user/` (reads `promtail-config.yaml` in place) | `cp` + `systemctl --user enable --now promtail` | `systemctl --user status promtail`; Grafana "Scrape Target Down" |
| `monitoring/aws-signing-helper/aws-signing-helper-grafana.service` | here → `~/.config/systemd/user/` (needs the untracked `~/.config/aws-signing-helper/grafana.env` from `grafana.env.example`, and cert `chad-host-grafana`) | `monitoring/aws-signing-helper/README.md` (`cp` + `systemctl --user enable --now aws-signing-helper-grafana`) | `curl -s http://127.0.0.1:9911/latest/meta-data/iam/security-credentials/`; Grafana "AWS — email" panels |
| `monitoring/logrotate/litellm-logrotate.{service,timer}` | here → `~/.config/systemd/user/` | `cp` + enable, or `scripts/rollout_observability.sh` | `systemctl --user list-timers` |
| `decap/decap-server.service` | here → `~/.config/systemd/user/` (loopback-only via `BIND_HOST`; Traefik `otbla-local-cms` is its only client) | `cp` + `systemctl --user daemon-reload` + `systemctl --user restart decap-server` | `ss -tlnp \| grep :8081` shows `127.0.0.1` only; `curl -sk -o /dev/null -w '%{http_code}' https://otbla-local.chadrbean.com/api/v1` → `401` |
| `hermes/systemd/hermes-watchdog.{sh,service}` | here → `~/.config/systemd/user/` (the script is **copied**; repo edits need a re-copy) | `cp` + `systemctl --user daemon-reload` | `journalctl --user -t hermes-watchdog` |
| `fail2ban/…` (`fail2ban.local`, `jail.d/`, `filter.d/`, exporter) | here → `/etc/fail2ban/`, `/etc/systemd/system/`, `/usr/local/bin/` | **sudo** `cp` / `fail2ban/exporter/install.sh` | `sudo fail2ban-client -t`; Grafana "Fail2ban Service Down" |
| `sshd/10-key-only.conf` | here → `/etc/ssh/sshd_config.d/10-key-only.conf` (`PasswordAuthentication no`, `PermitRootLogin no`, `DenyUsers automation`) | **sudo** `install -m 644`, `sshd -t`, then `systemctl reload ssh` (not restart) | `sudo sshd -T \| grep -iE 'passwordauth\|permitroot\|denyusers'` → `no`, `no`, `automation`; a password login attempt says `Permission denied (publickey)` |
| `sysctl/99-unpriv-443.conf` | here → `/etc/sysctl.d/99-unpriv-443.conf` (lets rootless Traefik bind `:443`; replaces sslh) | **sudo** `install -m 644`, then `sysctl --system` | `sysctl net.ipv4.ip_unprivileged_port_start` → `443`; `ss -tlnp \| grep :443` shows `traefik` |
| `scripts/awsChadHomeIp.sh` | here → `/usr/local/bin/` + `/etc/crontab` (hourly) | **sudo** `install -m 755` (file header) | none |
| `automation/sudoers.d/{10-chad-to-automation,automation}` | here → `/etc/sudoers.d/` (0440, root). Least-privilege root for Claude, see `automation/README.md` | **admin** (`su -`): `automation/install.sh` (validates with both `visudo` engines). Claude never installs these | `sudo -u automation sudo -n -l`; `automation/test.sh` |
| `automation/{host-read.py,host-repo.py,host-deploy.sh,f2b-unban.sh}` | here → `/usr/local/sbin/{host-read,host-repo,host-deploy,f2b-unban}` (root, 0755) | `automation/install.sh` | `automation/test.sh` |
| `automation/host-deploy.manifest` | here → `/etc/host-deploy/manifest` (root). Lists what `host-deploy` may install; not read from the clone | `automation/install.sh` | `sudo -u automation sudo -n /usr/local/sbin/host-deploy --check` (drift) |
| `hermes/config.yaml` | reference copy only. Live `~/.hermes/config.yaml` is untracked (secrets) | never deployed | none |

**sslh retired 2026-09-26.** Traefik binds `0.0.0.0:443` itself (dual-stack: `ss` shows `*:443`, so IPv6 is accepted
too; no AAAA records exist and the router should block inbound IPv6). The `sslh` package and
`/etc/default/sslh` stay on this host, service disabled, as a one-week rollback (see
`traefik/README.md`), then `sudo apt purge sslh` and delete this note.

The podman-compose stacks (`litellm/`, `monitoring/`, `traefik/`, …) read their
config in place from the **main checkout**, so for them, merging and then
`git pull` there is the deploy step (plus a container recreate where noted).

## One-time sudo steps (not scriptable from here)

| Step | Where | Command |
|---|---|---|
| LAN firewall for Loki/Prometheus | this host | `monitoring/firewall/README.md` → Install |
| Alloy package + drop-in | Zuriel's | `monitoring/alloy/deploy.sh stage`, then `ssh -t zuriel 'sudo bash /tmp/alloy-install.sh zuriel'` |

## Adding another desktop

1. Give it a static IP and an `~/.ssh/config` entry; install KopiaUI and connect
   its repository.
2. Kopia parity: `KOPIA_REMOTE_HOST=<host> kopia/sync-hosts.sh push`, then `email`,
   then `check`. `sync-hosts.sh` handles one remote at a time.
3. Monitoring: follow `monitoring/alloy/README.md` → First install (firewall
   `@pushers`, stage, install, check).
4. Alerts: copy `kopia_backup_stale_zuriel` in `log-alerts.yml` with the new
   `host=` value and a window that fits how often it's on.
5. Add a row to **Machines** and **Deployed files** above, and a node to
   `docs/monitoring.drawio`.

## Runbook

| Symptom | Check | Fix |
|---|---|---|
| No Kopia data from Zuriel's (`/d/kopia?var-host=wkspikaoszuriel` empty, stale alert) | `monitoring/alloy/deploy.sh check` | See the rows below for whichever line fails |
| `alloy.service not active` | `ssh zuriel journalctl -u alloy -n 50 --no-pager` | `ssh -t zuriel sudo systemctl restart alloy`. For config errors, fix `config.alloy` and `deploy.sh push` |
| `status=200/CHDIR` … `Permission denied` in the journal | `systemctl cat alloy` shows `WorkingDirectory=` | The package's `/var/lib/alloy` is 0700 `alloy`. The drop-in must set `WorkingDirectory=@HOME@/.local/share/alloy`, so re-run `deploy.sh stage` + `install.sh` |
| Components unhealthy / pushes failing | Alloy UI: `ssh -L 12345:127.0.0.1:12345 zuriel`, then http://127.0.0.1:12345 | `loki.write`/`remote_write` errors mean check the firewall and that this host's Loki/Prometheus are up |
| Firewall blocks pushes | `ssh zuriel curl -m5 -s 192.168.1.30:3100/ready` should say `ready` | IP in `@pushers`? `sudo systemctl restart monitoring-lan-firewall` |
| Loki rejects pushes (400/429) | `podman logs monitoring_loki \| tail` | Out-of-order or too old: normal for a few lines after a long offline period. Limits live in `monitoring/loki-config.yaml` |
| `DRIFT … config.alloy` / `drop-in` | `deploy.sh check` | `deploy.sh push` (config) or `stage` + `install.sh` (drop-in) |
| `/d/hosts` has no `wkspikaoschad` | `podman ps --filter name=monitoring_node_exporter`; Prometheus → Status → Targets → `node` | `cd ~/git/localsetup/monitoring && podman-compose up -d node-exporter` (after a prometheus.yml change also `podman restart monitoring_prometheus`) |
| Host disk almost full | `/d/hosts` → Filesystem used | Clean up. On Zuriel's, `/home` is the usual culprit (screen recordings are excluded from backup but still use disk) |
