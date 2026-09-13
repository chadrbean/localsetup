# Security Monitoring — fail2ban, dashboards, alerts, email

Date-stamped: **2026-09-12**. Shipped in PR #3 (merge `c81e29d`). Architecture diagram:
[`monitoring.drawio`](monitoring.drawio). Component details live in
[`../fail2ban/README.md`](../fail2ban/README.md), [`../monitoring/README.md`](../monitoring/README.md)
and [`../monitoring/promtail/README.md`](../monitoring/promtail/README.md). This page is the
end-to-end runbook covering what exists, how data flows, what each alert means, and how to deploy,
verify and troubleshoot it.

> **Deployment status (2026-09-12):** merged to `main`, **not yet deployed** to the live
> checkout/host. Follow [§8 Deploy](#8-deploy--update) once, then tick off [§9 Verify](#9-verify).

---

## 1. What this protects and watches

| Layer | Component | Runs as | Port | Role |
|---|---|---|---|---|
| Edge | sslh | native | public `:443` | Splits SSH vs TLS; SSH goes straight to sshd, never through Traefik |
| Edge | Traefik + fail2ban **HTTP plugin** | rootless podman | `:443` (via sslh), metrics `127.0.0.1:8082` | HTTP routes; primary HTTP abuse guard |
| Ban engine | **fail2ban** 1.1.0 | root, systemd | socket `/run/fail2ban/fail2ban.sock` | Jails `sshd`, `grafana`, `recidive`; bans via nftables `inet f2b-table` |
| State/health | **fail2ban_exporter** 0.10.3 | root, systemd | `127.0.0.1:9191` | `f2b_up`, per-jail banned/failed gauges, jail config |
| Logs | **Promtail** 3.1.1 | native user service (`chad`) | `127.0.0.1:9190` | Ships fail2ban.log, Traefik access log, Kopia logs to Loki |
| Store | Loki 3.1.1 | rootless podman | `127.0.0.1:3100` | 7d log retention |
| Store | Prometheus 2.53.1 | rootless podman (`user: 0:0`) | `127.0.0.1:9090` | 30d metrics, scrape-only |
| UI + alerting | Grafana 11.2 | rootless podman | `127.0.0.1:3000` → `https://grafana.chadrbean.com` | Dashboards, **all** alert rules, email |
| Delivery | Amazon SES SMTP | AWS us-west-2 | `email-smtp.us-west-2.amazonaws.com:587` | Alert email |

Baseline observed during the 2026-09-12 investigation: ~160 SSH auth failures and ~35 bans per
day, all against sshd arriving via sslh. `PasswordAuthentication no` already blocks the actual
attack. fail2ban cuts the noise and connection churn.

## 2. Data flow

```
 attacker ─▶ nftables (f2b-table) ─▶ sslh :443 ─┬─SSH─▶ sshd ──journald──┐
                                                └─TLS─▶ Traefik ─▶ Grafana ─journald (401 /api/login)─┐
                                                          │                                          ▼
                                                          │ access.log            fail2ban-server (root) ─ban─▶ nftables
                                                          │                          │ socket      │ /var/log/fail2ban.log
                                                          ▼                          ▼             ▼
                                                     Promtail ◀──────────────── exporter :9191   Promtail
                                                          │                          │
                                                   push   ▼                  scrape  ▼
                                                        Loki ──LogQL──▶ Grafana ◀──PromQL── Prometheus
                                                                          │
                                                                          └─SMTP 587─▶ SES us-west-2 ─▶ email
```

Two telemetry paths, by design:

- **Exporter → Prometheus** gives *current state and health* straight from fail2ban: currently
  banned, failing now, whether the service is alive. Logs can't reconstruct these reliably.
- **Log → Promtail → Loki** gives *events and detail*: every `Found`/`Ban`/`Unban`, per IP, per
  jail, plus errors. `loglevel = INFO` already emits all of them; DEBUG only adds noise.

## 3. fail2ban ban policy

Tracked in `fail2ban/`, copied to `/etc/fail2ban/` (no symlink).

| Jail | Watches | maxretry / findtime | Base bantime | Blocks |
|---|---|---|---|---|
| `sshd` | journald `_SYSTEMD_UNIT=ssh.service` | 4 / 10m | 3h | ssh |
| `grafana` | journald `CONTAINER_NAME=monitoring_grafana`, `POST /api/login` 401 | 5 / 10m | 1h | http, https |
| `recidive` | `/var/log/fail2ban.log`: same IP banned by any jail | 3 / 1d | 1w | **all ports** |

Global settings (`jail.d/00-defaults.conf`, `fail2ban.local`):

| Setting | Value | Why |
|---|---|---|
| `bantime.increment` | `true` | Each repeat ban doubles the base: sshd 3h → 6h → 12h → 24h → … |
| `bantime.maxtime` | `4w` | Escalation cap |
| `bantime.overalljails` | `true` | Prior bans from any jail count toward escalation |
| `bantime.rndtime` | `10m` | Jitter so botnets can't time the unban |
| `ignoreip` | `127.0.0.1/8 ::1 192.168.1.0/24` | Never ban loopback or the home LAN (plus `ignoreself`) |
| `dbpurgeage` | `30d` | Ban history must outlive `maxtime`. The Debian default of 1d silently disabled escalation and recidive |

**Caveat, grafana jail:** Traefik sees every client as `127.0.0.1` because sslh is not
transparent. Grafana's `remote_addr` therefore comes from `X-Forwarded-For`, which a client can
spoof. The jail is defense-in-depth; the Traefik plugin is the primary HTTP guard.

## 4. Data reference

### Exporter metrics (Prometheus job `fail2ban`)

| Metric | Meaning |
|---|---|
| `f2b_up` | 1 = exporter reached fail2ban's socket. 0 = fail2ban down or socket unreadable |
| `f2b_errors{type="socket_conn"\|"socket_req"}` | Counter of socket connect / request errors |
| `f2b_jail_count` | Jails running (expected **3**) |
| `f2b_jail_banned_current{jail}` | IPs banned right now |
| `f2b_jail_failed_current{jail}` | IPs with failures inside findtime, not yet banned |
| `f2b_jail_banned_total{jail}` / `f2b_jail_failed_total{jail}` | Since fail2ban start (reset on restart) |
| `f2b_config_jail_ban_time` / `_find_time` (s), `f2b_config_jail_max_retries` | Base jail config |

### Loki streams

| `job` | Labels (bounded) | Structured metadata (unbounded) |
|---|---|---|
| `fail2ban` | `logger`, `level`, `jail`, `action` ∈ `Found`, `Ban`, `Unban`, `Restore Ban`, `AlreadyBanned` | `ip` |
| `traefik` | `status`, `method`, `router` | `req_host`, `path` |
| `kopia` | `level`, `component` | — |

**Rule:** attacker-controlled values (IP, Host header, path) are never labels, because each distinct
value creates a stream. Before PR #3 `ip` was a label and grew one stream per attacker.

Useful queries:

```logql
# bans per jail, last hour
sum by (jail) (count_over_time({job="fail2ban", action="Ban"}[1h]))
# top 10 attacking IPs, 24h (structured metadata)
topk(10, sum by (ip) (count_over_time({job="fail2ban", action="Found"} | ip!="" [24h])))
# everything one IP did
{job="fail2ban"} | ip="62.60.130.201"
# fail2ban errors (broken filter, failed action)
{job="fail2ban", level=~"ERROR|CRITICAL"}
```

```promql
sum(f2b_jail_banned_current)                               # banned now
(min(f2b_up) * min(up{job="fail2ban"})) or on() vector(0)  # 1 = healthy (same expr as the alert)
```

## 5. Dashboards

Tracked in `monitoring/dashboards/` and provisioned into Grafana folder **Ops**. Edit the JSON in
the repo; UI edits are disabled and the files are re-read every 30s.

| Dashboard | URL | Panels |
|---|---|---|
| **fail2ban** | `/d/fail2ban` | **Status:** service UP/DOWN, currently banned, IPs failing now, bans 24h, recidive bans 7d, last log line shipped · **Activity:** bans (up) vs unbans (down), failures per jail, currently banned over time, unique attacking IPs/h · **Offenders & policy:** top offending IPs, repeat offenders, jail policy table · event log · **Health:** collectors up, exporter socket errors, WARNING/ERROR lines. Variable `$jail`. |
| **Traefik HTTP Security** | `/d/traefik-security` | Req/s, 4xx share, 5xx, open connections, TLS cert days left, config reload · status codes, 4xx/5xx by service · 401/403 by router, 404s by router (empty = unrouted scans) · top 404 paths, top rejected Host headers · p95 latency, Grafana login failures · 4xx/5xx log. No client-IP panels, because every client appears as loopback via sslh. |
| **Kopia Backups** | `/d/kopia` | Last snapshot, snapshots 24h, snapshot file errors, warnings · data size / longest duration / files per hour, maintenance · snapshot summaries, WARN/ERROR log |

## 6. Alerts and what to do

All rules are **Grafana-managed** (`monitoring/provisioning/alerting/`); Prometheus has no rule
files and no Alertmanager. Notification policy (`contact-points.yml`):

- one email contact point, `email-alerts`, sending to `$ALERT_EMAIL_TO`
- grouped by folder + alert name
- 30s group wait, 5m group interval, 4h repeat, resolve notices on

| Alert | Severity | Fires when | First response |
|---|---|---|---|
| **Fail2ban Service Down** | critical | `f2b_up × up{job="fail2ban"}` < 1 for 2m | `sudo systemctl status fail2ban fail2ban-exporter`; `sudo fail2ban-client -t` (config error?); `journalctl -u fail2ban -n 50` |
| Fail2ban Jail Missing | warning | `f2b_jail_count` < 3 for 5m while up | `sudo fail2ban-client status`; `grep ERROR /var/log/fail2ban.log` (usually a filter without `<HOST>`) |
| Fail2ban Log Errors | warning | any ERROR/CRITICAL line in 15m | Health row on `/d/fail2ban`; fix the jail/action named in the line |
| Fail2ban Log Pipeline Silent | warning | no fail2ban lines in Loki for 3h | `systemctl --user status promtail`; log rotated to a new inode? `sudo tail /var/log/fail2ban.log` |
| Scrape Target Down | warning | any Prometheus job `up == 0` for 3m (one alert per job) | `http://127.0.0.1:9090/targets` shows the scrape error |
| Promtail Dropping Logs | warning | `promtail_dropped_entries_total` rose in 10m | `journalctl --user -u promtail`; Loki rate/stream limits |
| TLS Certificate Expiring | warning | cert < 14 days for 1h | `podman logs traefik \| grep -i acme` (Route53 DNS-01 renewal) |
| Fail2ban Ban Spike | warning | > 10 bans in 5m | Check `/d/fail2ban` top offenders; coordinated wave, usually self-resolving |
| Fail2ban High Ban Rate | critical | > 40 bans/h sustained 15m | Sustained campaign. Confirm recidive is catching repeats; consider tightening sshd maxretry |
| Kopia Backup Warning | warning | no snapshot in 3h (30m pending) | KopiaUI not running? Snapshots only happen while the desktop app is open |
| Kopia Backup Stale | critical | no snapshot in 26h | Open KopiaUI; check the S3 repository connection |
| Kopia Snapshot Errors | warning | snapshot summary `errors` > 0 in 2h | Kopia log panel lists the unreadable files |
| *DatasourceError* (built-in) | — | Prometheus or Loki unreachable while evaluating | `podman ps`; restart `monitoring_prometheus` / `monitoring_loki` |

## 7. Alert email (SES SMTP)

- **Credentials already exist**: the Terraform-managed IAM user **`hermes-ses-email`** in
  `~/git/aws-infrastructure` (`terraform/modules/dns/main.tf`). Hermes itself sends through Gmail,
  so this user is otherwise unused. **Don't create IAM users out-of-band.**

  | Grafana setting (`monitoring/.env`) | Source |
  |---|---|
  | `GRAFANA_SMTP_HOST` | `email-smtp.us-west-2.amazonaws.com:587` |
  | `GRAFANA_SMTP_USER` | `terraform output -raw hermes_ses_email_access_key_id` |
  | `GRAFANA_SMTP_PASSWORD` | `terraform output -raw hermes_ses_email_smtp_password` (already SigV4-derived) |
  | `GRAFANA_SMTP_FROM` | **`hermes@chadrbean.com`**, the only sender the IAM policy allows (`ses:FromAddress` condition) |
  | `ALERT_EMAIL_TO` | Must be a verified SES identity in us-west-2 |

- **SES us-west-2 is in the sandbox**: 200 messages/day, and every recipient must be verified.
  Verified as of 2026-09-12: `chadrbean.com`, `crb4u@yahoo.com`.
- The legacy us-west-1 `chadrbean.com` identity, used by `~/.claude/bin/send-email`, is separate
  and unmanaged. Grafana does not use it.
- To send as `grafana@chadrbean.com`, add it to the policy condition in aws-infrastructure and apply.

## 8. Deploy / update

The running services read config from the **main checkout** `~/git/localsetup`. Steps:

1. **Update the checkout.** It still holds uncommitted copies of files that are now in `main`
   (Loki/Promtail/alerting from the pre-PR baseline), so `git pull` will refuse with *"untracked
   working tree files would be overwritten"*. Move or stash those local copies first. Keep the
   unrelated in-progress work (litellm, traefik, hermes, scripts; see draft PR #2). Then
   `git pull`.
2. **Remove duplicate dashboards.** The old copies in the git-ignored folder share uids with the
   tracked ones:
   `mv monitoring/data/dashboards/{fail2ban,kopia}.json /tmp/`
3. **Email env.** Append to `monitoring/.env` without echoing secrets:
   ```bash
   TF=~/git/aws-infrastructure/terraform
   {
     echo "GRAFANA_SMTP_HOST=email-smtp.us-west-2.amazonaws.com:587"
     echo "GRAFANA_SMTP_USER=$(terraform -chdir=$TF output -raw hermes_ses_email_access_key_id)"
     echo "GRAFANA_SMTP_PASSWORD=$(terraform -chdir=$TF output -raw hermes_ses_email_smtp_password)"
     echo "GRAFANA_SMTP_FROM=hermes@chadrbean.com"
     echo "ALERT_EMAIL_TO=crb4u@yahoo.com"
   } >> monitoring/.env && chmod 600 monitoring/.env
   ```
   `ALERT_EMAIL_TO` is **required**; compose refuses to start Grafana without it.
4. **fail2ban** (sudo):
   ```bash
   cd ~/git/localsetup/fail2ban
   sudo cp fail2ban.local /etc/fail2ban/ && sudo cp jail.d/*.conf /etc/fail2ban/jail.d/ && sudo cp filter.d/*.conf /etc/fail2ban/filter.d/
   sudo fail2ban-client -t && sudo systemctl restart fail2ban
   sudo ./exporter/install.sh          # ends by printing f2b_up 1 and f2b_jail_count 3
   grep -q wkspikaoschad /etc/hosts || echo "127.0.1.1 wkspikaoschad" | sudo tee -a /etc/hosts
   ```
5. **Collectors + stack:**
   ```bash
   cd ~/git/localsetup/monitoring
   ~/.local/bin/promtail -check-syntax -config.file=promtail/promtail-config.yaml
   systemctl --user restart promtail
   podman-compose up -d                 # recreates prometheus (user 0:0) + grafana (SMTP env, new mounts)
   podman restart monitoring_grafana    # only if compose didn't recreate it (reloads alerting provisioning)
   ```

Expected right after deploy: **Kopia Backup Warning/Stale** go pending until the next hourly
snapshot, because the snapshot-summary lines only flow once the new Promtail pipeline is live.
They resolve on their own.

## 9. Verify

- [ ] `sudo fail2ban-client status` → `sshd, grafana, recidive`; `sudo fail2ban-client get dbpurgeage` → `2592000`
- [ ] `curl -s 127.0.0.1:9191/metrics | grep -E '^f2b_(up|jail_count) '` → `1`, `3`
- [ ] `http://127.0.0.1:9090/targets`: `fail2ban`, `litellm`, `traefik`, `loki`, `promtail`, `prometheus` all **UP**
- [ ] `curl -s 127.0.0.1:3100/loki/api/v1/labels`: **no** `ip` label; `{job="fail2ban"} | ip!=""` returns rows
- [ ] Grafana → Alerting: all 12 rules `Normal`/`Pending`, **no** `Error`
- [ ] Contact point test: Alerting → Contact points → `email-alerts` → **Test** → email arrives from `hermes@chadrbean.com`
- [ ] Ban flow: `sudo fail2ban-client set sshd banip 203.0.113.55` → appears on `/d/fail2ban` (event log, currently banned +1) → `unbanip` → drops back
- [ ] Alert end-to-end: `sudo systemctl stop fail2ban`, wait about 3 min → **Fail2ban Service Down** email → `sudo systemctl start fail2ban` → resolved email

Pre-merge validation (2026-09-12) ran a throwaway Grafana 11.2 with this provisioning against live
Loki and Prometheus: 12/12 rules `health=ok`, and 45 panel queries ran with 0 errors. It also
included `promtail --stdin --dry-run` per job and `promtail -check-syntax`.

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Promtail won't start: `invalid selector syntax for match stage … expecting STRING` | Match-stage selectors reject LogQL `` `backtick` `` strings (`-check-syntax` does **not** catch it) | Use an escaped double-quoted regex; test with `promtail --stdin --dry-run -config.file=…` |
| `f2b_up 0`, exporter log `connect: permission denied` | Exporter not running as root (socket is `0700 root`) | Use the provided unit (`User=root`); `ReadWritePaths=/run/fail2ban` |
| Prometheus `litellm` target DOWN: `unable to read authorization credentials` | Container user can't read the 0600 `bearer_token` | `user: "0:0"` in compose (rootless root = host `chad`); don't loosen chmod |
| `podman-compose up`: `set ALERT_EMAIL_TO in monitoring/.env` | Required variable missing | §8 step 3 |
| Test email fails: `554 Access denied … ses:SendRawEmail` | Sender isn't `hermes@chadrbean.com` | Set `GRAFANA_SMTP_FROM=hermes@chadrbean.com` |
| Test email fails: `MessageRejected: Email address is not verified` | Sandbox; recipient not verified in **us-west-2** | `aws sesv2 create-email-identity --email-identity <addr> --region us-west-2`, click the link |
| Dashboard flips between versions / "provisioned dashboard with same uid" | Same uid in `data/dashboards/` and `dashboards/` | Remove the copy from `monitoring/data/dashboards/` |
| Grafana UI "Save" on a tracked dashboard fails | `allowUiUpdates: false` | Edit `monitoring/dashboards/*.json` in the repo |
| `ipdns WARNING Unable to find a corresponding IP address for wkspikaoschad` | Hostname doesn't resolve | `/etc/hosts` entry (§8 step 4) |
| Local failed SSH/Grafana logins never ban | `ignoreself` / `ignoreip` (by design) | Test with `fail2ban-client set <jail> banip 203.0.113.x` |
| Jail silently missing after edit | Custom filter lacks a `<HOST>` group, so fail2ban refuses the jail | `sudo fail2ban-client -t`; **Fail2ban Jail Missing** alert fires |
| "Last snapshot" / Kopia panels empty | KopiaUI not running, or Promtail restarted before a new snapshot | Wait for the hourly snapshot; check KopiaUI |
| Loki stream count creeping up | A new unbounded value was added as a label | Move it to `structured_metadata` in Promtail |

## 11. Open items

- **Deploy** (§8) and **verify** (§9). Not done as of 2026-09-12.
- **Draft PR #2 (LiteLLM observability)** started from the same monitoring baseline and must be
  rebased onto `main`. Text conflicts:
  - `README.md`
  - `monitoring/{.env.example, README.md, docker-compose.yml, prometheus.yml}`
  - `monitoring/promtail/{README.md, promtail-config.yaml}`
  - `monitoring/provisioning/alerting/log-alerts.yml`
  - `monitoring/provisioning/dashboards/dashboards.yml`

  Semantic duplicates to reconcile:
  - **Notification policy:** its `notifications.yml` (`email-chad`) vs `contact-points.yml`. Only one policy tree is allowed.
  - **Duplicate rules:** its Promtail/Loki Down and Promtail Dropping Logs rules.
  - **SES:** its planned `grafana-ses-smtp` IAM user; reuse `hermes-ses-email` instead.

  Details are in the PR #2 comment.
- Deferred ideas:
  - GeoIP for banned IPs (Promtail `geoip` stage; needs a MaxMind key)
  - top attempted SSH usernames (Promtail journal scrape; needs `chad` in `systemd-journal`)
  - a dedicated `grafana@chadrbean.com` sender

## 12. History — what was broken before PR #3 (2026-09-12 investigation)

| Finding | Impact |
|---|---|
| Only contact point `<example@email.com>`, no SMTP, no Alertmanager | No alert ever delivered |
| fail2ban/Kopia rules used `unwrap _` and `classic_conditions` math strings | Loki HTTP 400 every minute; Kopia Backup Stale stuck firing; fail2ban rules never evaluated |
| "Currently banned" panel subtracted log-count vectors | Always empty |
| No fail2ban service metric | fail2ban could die unnoticed |
| `ip` as a Loki label; loose regexes produced junk `level` values | Unbounded streams; bad label data |
| `dbpurgeage = 1d`, no recidive, no LAN `ignoreip` | No escalation for repeat offenders |
| Prometheus container as `nobody` vs 0600 token | LiteLLM target DOWN since 2026-09-11 |
| Dashboards in git-ignored `monitoring/data/` | Not version-controlled |
| Hostname unresolvable | ~40 `ipdns` warnings; weaker `ignoreself` |
| Note: `\|= "Ban"` is case-sensitive, so it does **not** match `Unban`. Old ban counts were correct | — |
