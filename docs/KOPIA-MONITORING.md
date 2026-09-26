# Kopia backup monitoring

How both desktops' Kopia backups are known to be healthy, and how you find out
when they aren't. The hosts are this one (`host="wkspikaoschad"`, via Promtail) and
Zuriel's workstation (`host="wkspikaoszuriel"`, via Alloy; see
[HOSTS.md](HOSTS.md)). Kopia itself (install, policies, restore) is in
[kopia/README.md](../kopia/README.md); the monitoring stack is in
[monitoring/README.md](../monitoring/README.md).

## TL;DR

- **Dashboard:** https://grafana.chadrbean.com/d/kopia (`$host` picks the desktop)
- **You get an email when:**
  - no snapshot has completed successfully in **24 hours** on this host, or
    **72 hours** on Zuriel's (Grafana, critical; his PC is off for days)
  - no snapshot in 3 hours on this host (Grafana, warning; hourly schedule)
  - a snapshot **fails or warns** on either host (Kopia's own notification, includes the error)
  - Kopia logs WARN/ERROR lines, files fail to back up, or S3 operations fail (Grafana, per host)
- **Check it all works:** `python3 scripts/check_kopia_monitoring.py`,
  `kopia/sync-hosts.sh check`, `monitoring/alloy/deploy.sh check`

## How it works

```
KopiaUI (kopia server, hourly snapshots) ──▶ S3 chadrbean-backups
   │                          │
   │ DEBUG file log           │ snapshot-report (severity ≥ warning)
   ▼                          ▼
~/.cache/kopia/cli-logs   Kopia notification profile ──SMTP──▶ SES us-west-2 ──▶ email
   │ tail (allow-list)
   ▼
Promtail :9190 ──push──▶ Loki :3100 ◀──LogQL── Grafana :3000 ──SMTP──▶ SES ──▶ email
  host=wkspikaoschad       ▲                   (dashboard + alert rules)
                           │ push over the LAN (nftables allow-list, monitoring/firewall/)
Zuriel's workstation: KopiaUI ─▶ S3 bigpoopfart-backups
  ~/.cache/kopia/cli-logs ─▶ Alloy (same pipeline stages) host=wkspikaoszuriel
  + its own ses-email notification profile ─▶ SES ─▶ email
```

There are **two email paths on purpose**:

| Path | Catches | Why |
|---|---|---|
| Grafana alert rules on Kopia's logs | snapshots that **didn't happen** (KopiaUI not running, repo disconnected, scheduler stuck, log pipeline broken) | only something outside Kopia can notice silence |
| Kopia notification profile `ses-email` | snapshots that **ran and failed/warned** | Kopia logs `finished uploading` on success *and* failure — the error is only in its report |

Kopia 0.23.1 has no per-snapshot Prometheus metrics (upstream PR #4100 is
unmerged), so all Grafana signals are derived from the log.

### Log signals (Promtail `event` label)

Promtail keeps an allow-list of Kopia log lines and labels them
(`monitoring/promtail/promtail-config.yaml`):

| `event` | Kopia line | Also |
|---|---|---|
| `snapshot_start` | `kopia/server uploading <user@host:path>` | `source` label |
| `snapshot_finished` | `kopia/server finished uploading <src>` — success **or** failure | `source` label |
| `snapshot_summary` | root dir `snapshotted directory {"path":"."…}` without error = **successful snapshot** | json `dur,size,files,dirs,errors` |
| `file_error` | a snapshotted entry with `"error":"…"` | json `path,error` |
| `storage` | S3 `PutBlob/GetBlob/ListBlobs/DeleteBlob` | `op` label; json `duration,length,error` |
| `retention_delete` | snapshot removed by retention | — |
| `maintenance` | `maintenance` / `snapshotgc` | — |
| `error` | any WARN/ERROR/FATAL line | — |

`source` values on this host: `chad@wkspikaoschad:/home/chad`,
`…:/home/chad/.local/share/wave`, `…:/usr/local/bin`. The root summary line
carries no source, so size/duration/files panels show the rolling 1 h max
(≈ `/home/chad`).

Trend panels evaluate a **rolling 1 h window every 5 min** (`step: 5m`), not
aligned hourly buckets. Loki rounds a range query's end up to the step, so an
hourly step stamps the current hour's bucket in the future and Grafana clips it:
a host with one snapshot showed empty charts and "last snapshot finished: in 43
minutes" until the hour ended. "Last snapshot finished" uses a 5 min window for
the same reason.

### Kopia settings that make this work

- **Global logging policy** `--log-entry-snapshotted=0 --log-entry-ignored=0`
  (`kopia/policies/global.json`): drops per-file lines (~99% of a ~50 MB / 3 h
  log) while errored files are still logged. `--log-dir-snapshotted` stays `5`
  — the root summary line depends on it.
- **Autostart env** `KOPIA_LOG_DIR_MAX_SIZE_MB=500 KOPIA_CONTENT_LOG_DIR_MAX_SIZE_MB=200`
  (`kopia/kopia-ui-autostart.desktop`) caps Kopia's log directories.
- **Notification profile** `ses-email`, `--min-severity=warning` — setup
  command in [kopia/README.md](../kopia/README.md#monitoring--notifications).

## Alerts

All Grafana rules are in `monitoring/provisioning/alerting/log-alerts.yml`
(group `kopia`, folder `Logs`) and route to contact point `email-alerts`
(`contact-points.yml`, recipient `ALERT_EMAIL_TO`).

| Rule | Host | Fires when | No data means | Severity |
|---|---|---|---|---|
| **Kopia Backup Stale** | `wkspikaoschad` | 0 `snapshot_summary` lines in 24h | alerting (silence = problem) | critical |
| **Kopia Backup Stale (Zuriel)** | `wkspikaoszuriel` | 0 `snapshot_summary` lines in 72h | alerting | critical |
| Kopia Backup Warning | `wkspikaoschad` | 0 snapshot summaries in 3h, for 30m | alerting | warning |
| Kopia Snapshot Errors | each (`by (host)`) | summary `errors` > 0 in 2h | OK | warning |
| Kopia S3 Storage Errors | each | S3 op with `"error":"…"` in 15m, for 5m | OK | critical |
| Kopia Log Errors | each | `event=~"error\|file_error"` in 15m | OK | warning |

Staleness rules are **one per host** with a `host=` filter. A `sum by (host)`
rule can't alert on a host that sends nothing: its series just disappears.
A new desktop therefore needs its own `kopia_backup_stale_*` rule.

Related health rules (`health-alerts.yml`): **Scrape Target Down** (incl.
Promtail/Loki) and **Promtail Dropping Logs**. If Loki is down, Kopia rules
error and Grafana sends a `DatasourceError` email.

## Email delivery

Amazon SES SMTP, `email-smtp.us-west-2.amazonaws.com:587` (STARTTLS), configured
in `monitoring/.env`: `GRAFANA_SMTP_USER`, `GRAFANA_SMTP_PASSWORD`,
`GRAFANA_SMTP_FROM`, `ALERT_EMAIL_TO`. SES us-west-2 is in the **sandbox**
(200/day): sender domain `chadrbean.com` and the recipient are verified
identities there. The same SMTP user and recipient feed Grafana and both hosts'
Kopia `ses-email` profiles. The Kopia profiles send as `kopia@chadrbean.com`.
Zuriel's profile is (re)created from `monitoring/.env` with
`kopia/sync-hosts.sh email`, which pipes the creds over ssh stdin.
Credential sourcing is described in monitoring/README.md → "Alert email (SES SMTP)".

## Dashboard `/d/kopia`

`monitoring/dashboards/kopia.json` (tracked, provisioned read-only — edit the
JSON, not the UI). Variable `$host` (from the Loki `host` label) filters every
panel, and the aggregate panels are split `by (host)`. `$source` narrows the
per-source panels to that host's sources.

| Row | Panels |
|---|---|
| Health | Last snapshot finished (per source), snapshots finished 24h, successful snapshots 24h, warnings & errors 24h, S3 errors 24h, Kopia alert list |
| Snapshot trends | Snapshots/hour by source, largest snapshot size, longest duration, files, retention deletions/hour |
| S3 storage | S3 ops/hour by op, p95 latency by op, bytes uploaded/hour |
| Logs | Snapshot events (with size/files/errors), warnings & errors, Kopia log volume shipped, maintenance activity |

## Verify / test

```bash
# every dashboard query through Grafana + kopia rule health + contact point
python3 scripts/check_kopia_monitoring.py

# Kopia labels present in Loki
curl -s http://127.0.0.1:3100/loki/api/v1/label/event/values

# Grafana email: Alerting → Contact points → email-alerts → Test
#   (API form in monitoring/README.md)

# Kopia email
K="/opt/KopiaUI/resources/server/kopia --config-file $HOME/.config/kopia/repository.config"
$K notification profile test --profile-name=ses-email
```

Testing a Promtail pipeline change: see
[monitoring/promtail/README.md](../monitoring/promtail/README.md#kopia-events-volume-control)
(dry run + backfill).

## Runbook

| Symptom | Check | Fix |
|---|---|---|
| **Kopia Backup Stale / Warning** | Is KopiaUI running? `pgrep -f 'kopia server start'` | Start KopiaUI (it only snapshots while the desktop app runs); autostart entry in `kopia/README.md` |
| | Last snapshots: `$K snapshot list --all \| tail` | If snapshots exist but alert fires → log pipeline: `systemctl --user status promtail`, `curl -s 127.0.0.1:3100/ready` |
| | Repo connected? `$K repository status` | Reconnect (kopia/README.md → Restore from scratch, step 2) |
| **Kopia Backup Stale (Zuriel)** | Is the PC on? `ssh zuriel uptime`. Then `ssh zuriel pgrep -f 'kopia server start'` | Off for 3+ days: nothing to fix. Otherwise start KopiaUI there; if snapshots exist (`ssh zuriel $K snapshot list \| tail`), it's the log path: `monitoring/alloy/deploy.sh check` (service, firewall, Loki), see [HOSTS.md](HOSTS.md) runbook |
| **Kopia S3 Storage Errors** | Dashboard → Warnings & errors; `{job="kopia", event="storage"} \|= "\"error\":\""` | AWS credentials in `repository.config`, network, bucket policy |
| **Kopia Snapshot Errors / Log Errors** | `{job="kopia", event="file_error"}` shows the path + error | Permission-denied/vanished files: fix perms or add to `.kopiaignore` |
| Kopia failure email | The email contains the error | Same as above |
| **Backup keeps growing** (size/files up every hour) | `$K snapshot list /home/chad`, then diff two snapshots: `$K ls -l <old-id>` vs `<new-id>` and drill into the dir that grew | Usually a leak (2026-09-25: Hermes restart loop left ~62 GB of `.dist-build-*` dirs). Fix the source, add the path to `.kopiaignore` (kopia/README.md → Exclusions), then delete the bloated snapshots |
| Dashboard empty | `python3 scripts/check_kopia_monitoring.py` | Loki/Promtail down, or labels missing → re-run Promtail backfill |
| No emails at all | Grafana logs: `podman logs monitoring_grafana \| grep -i smtp` | `monitoring/.env` SMTP values; SES sandbox recipient verified in us-west-2 |

## Limits

- **Local only:** if this host is off or asleep, nothing fires. An off-box
  dead-man switch (e.g. healthchecks.io pinged from a Kopia after-snapshot
  action) would cover that; not set up.
- Size/duration/files panels can't split by source (the summary line has no
  source). They split by host, and each host's largest source is its home.
- Loki retention is 7 days — dashboard history is at most a week.
