# monitoring/ — observability stack (Prometheus, Grafana, Loki, Promtail)

A podman compose stack (pod `pod_monitoring`) running on the host. Manage it
directly with `podman-compose <args>` from this directory; secrets live in
`monitoring/.env` (git-ignored, auto-loaded by podman-compose — template in
`.env.example`). Architecture diagram: [`../docs/monitoring.drawio`](../docs/monitoring.drawio); end-to-end runbook: [`../docs/SECURITY-MONITORING.md`](../docs/SECURITY-MONITORING.md).

## Components

| Service | Image / binary | Port | Notes |
|---|---|---|---|
| **Prometheus** | `prom/prometheus:v2.53.1` | `127.0.0.1:9090` | 30d retention. Scrape-only (no rule files). Runs as `user: 0:0` (= host `chad`, rootless) so it can read the 0600 LiteLLM bearer token. |
| **Grafana** | `grafana/grafana-oss:11.2.0` | `127.0.0.1:3000` | Public at `https://grafana.chadrbean.com` via traefik (fail2ban middleware only). Own admin login. **Owns all alerting**; emails via SES SMTP. |
| **Loki** | `grafana/loki:3.1.1` | `127.0.0.1:3100` | Single-binary, filesystem store, 7d retention, structured metadata on. |
| **Promtail** | `promtail-linux-amd64:3.1.1` | `127.0.0.1:9190` | **Native systemd user service** (see `promtail/README.md`). Tails fail2ban, Traefik access and Kopia logs. |
| **fail2ban exporter** | `fail2ban_exporter` 0.10.3 | `127.0.0.1:9191` | **Native root system service** (`../fail2ban/exporter/`) — needs the root-only fail2ban socket. |

Everything uses host networking / loopback listeners; traefik is the only
public ingress.

## Data flow

```
 LiteLLM :4000 /metrics/ (bearer) ─┐
 Traefik :8082 /metrics ───────────┤
 fail2ban socket ─▶ exporter :9191 ┼──scrape──▶ Prometheus :9090 ─┐
 Loki / Promtail self-metrics ─────┘                               │
                                                                    ├──▶ Grafana :3000 ──SMTP──▶ SES ──▶ email
 /var/log/fail2ban.log ─┐                                           │    (dashboards + alert rules)
 traefik access.log ────┼──▶ Promtail :9190 ──push──▶ Loki :3100 ──┘
 kopia cli-logs ────────┘
```

## Files

```
monitoring/
├── docker-compose.yml             # loki, prometheus, grafana
├── prometheus.yml                 # scrape jobs (litellm, traefik, loki, promtail, fail2ban)
├── prometheus/bearer_token        # git-ignored; LiteLLM scrape auth
├── loki-config.yaml               # single-binary, 7d retention
├── promtail/
│   ├── README.md                  # native-install reasoning, label/metadata rules
│   ├── promtail-config.yaml       # scrape jobs + pipelines
│   └── promtail.service           # systemd user unit
├── provisioning/
│   ├── dashboards/dashboards.yml  # 2 providers: data/dashboards (General), dashboards/ (Ops)
│   ├── datasources/
│   │   ├── prometheus.yml         # uid pinned: PBFA97CFB590B2093
│   │   └── loki.yml               # uid: loki
│   └── alerting/
│       ├── contact-points.yml     # email contact point + notification policy
│       ├── health-alerts.yml      # service/collector health (Prometheus + Loki)
│       └── log-alerts.yml         # fail2ban attack volume, Kopia freshness (Loki)
├── dashboards/                    # TRACKED dashboard JSON (folder "Ops")
│   ├── fail2ban.json              # /d/fail2ban
│   ├── traefik-security.json      # /d/traefik-security
│   └── kopia.json                 # /d/kopia
└── data/dashboards/               # git-ignored, fetched JSON (LiteLLM)
```

## Manage

```bash
podman-compose config                          # validate compose (needs .env)
podman-compose up -d                            # start / apply compose changes
podman restart monitoring_grafana               # reload alerting/datasource provisioning
podman ps --format "{{.Names}}\t{{.Status}}"   # status (podman-compose ps is unreliable)
```

Dashboards in `dashboards/` are re-read every 30s — edit the JSON in the repo
(UI edits are disabled for provisioned dashboards). Alert-rule, contact-point
and datasource changes need a Grafana restart.

Promtail (native) is managed separately:
```bash
~/.local/bin/promtail -check-syntax -config.file=promtail/promtail-config.yaml
systemctl --user restart promtail
journalctl --user -u promtail -f
```

## Dashboards

| Dashboard | Sources | Highlights |
|---|---|---|
| **fail2ban** `/d/fail2ban` | exporter + Loki | Service UP/DOWN, currently banned, IPs failing now, bans 24h, recidive 7d, log freshness; bans vs unbans, failures per jail, banned-over-time, unique attacker IPs/h; top offenders, repeat offenders, jail policy table; event log; collector health |
| **Traefik HTTP Security** `/d/traefik-security` | Traefik metrics + access log | Req/s, 4xx share, 5xx, open conns, cert days left, config reload; status codes, 4xx/5xx by service, 401/403 by router, 404s by router, top 404 paths, top rejected Host headers, p95 latency, Grafana login failures, error log |
| **Kopia Backups** `/d/kopia` | Loki | Last snapshot, snapshots 24h, file errors, warnings; size/duration/files per hour, maintenance; snapshot summaries + WARN/ERROR log |
| **LiteLLM Prod v2** | Prometheus | Fetched by `scripts/fetch_litellm_dashboard.sh` |

Traefik panels have no client-IP breakdown: sslh forwards to Traefik over
loopback, so `ClientHost` is always `127.0.0.1`.

## Alerting

All rules are **Grafana-managed** (Prometheus has no Alertmanager), so there
is one notification path: `contact-points.yml` → email to `$ALERT_EMAIL_TO`,
grouped by folder + alert name, repeated every 4h while firing, with resolve
notices. List: `https://grafana.chadrbean.com/alerting/list`.

| Rule | Folder | Condition | Severity |
|---|---|---|---|
| Fail2ban Service Down | Health | `f2b_up × up{job="fail2ban"}` < 1 for 2m (fail2ban or exporter dead) | critical |
| Fail2ban Jail Missing | Health | `f2b_jail_count` < 3 for 5m (while up) | warning |
| Fail2ban Log Errors | Health | any ERROR/CRITICAL line in fail2ban.log (15m) | warning |
| Fail2ban Log Pipeline Silent | Health | no fail2ban log lines in Loki for 3h | warning |
| Scrape Target Down | Health | any Prometheus job `up == 0` for 3m (per job) | warning |
| Promtail Dropping Logs | Health | `promtail_dropped_entries_total` increased in 10m | warning |
| TLS Certificate Expiring | Health | Traefik cert < 14 days for 1h | warning |
| Fail2ban Ban Spike | Logs | > 10 bans in 5m | warning |
| Fail2ban High Ban Rate | Logs | > 40 bans/h for 15m | critical |
| Kopia Backup Warning | Logs | no snapshot in 3h for 30m | warning |
| Kopia Backup Stale | Logs | no snapshot in 26h | critical |
| Kopia Snapshot Errors | Logs | snapshot `errors` > 0 in 2h | warning |

If Prometheus or Loki is itself down, rule queries error and Grafana raises a
`DatasourceError` alert through the same email path.

### Alert email (SES SMTP)

Grafana sends through Amazon SES SMTP in **`us-west-2`**
(`email-smtp.us-west-2.amazonaws.com:587`) using the existing
**Terraform-managed `hermes-ses-email` IAM user** from `~/git/aws-infrastructure`
(`terraform/modules/dns/main.tf`). No new IAM user is needed.

| Setting | Value / source |
|---|---|
| SMTP username | `terraform output -raw hermes_ses_email_access_key_id` |
| SMTP password | `terraform output -raw hermes_ses_email_smtp_password` (already SigV4-derived — do **not** use the raw secret key) |
| From address | **`hermes@chadrbean.com`** — the user's IAM policy has `Condition ses:FromAddress = hermes@chadrbean.com`; any other sender is denied. Grafana shows display name "Grafana (localsetup)". |
| Recipient | `ALERT_EMAIL_TO` — SES us-west-2 is in the **sandbox** (200/day), so it must be a verified identity there |

Populate `monitoring/.env` without echoing secrets:

```bash
TF=~/git/aws-infrastructure/terraform
{
  echo "GRAFANA_SMTP_HOST=email-smtp.us-west-2.amazonaws.com:587"
  echo "GRAFANA_SMTP_USER=$(terraform -chdir=$TF output -raw hermes_ses_email_access_key_id)"
  echo "GRAFANA_SMTP_PASSWORD=$(terraform -chdir=$TF output -raw hermes_ses_email_smtp_password)"
  echo "GRAFANA_SMTP_FROM=hermes@chadrbean.com"
  echo "ALERT_EMAIL_TO=<verified address>"
} >> monitoring/.env
chmod 600 monitoring/.env
podman-compose up -d grafana
```

Check the recipient is verified:
`aws sesv2 get-email-identity --email-identity <addr> --region us-west-2`.
To send as a dedicated `grafana@chadrbean.com` instead, add it to the policy's
`ses:FromAddress` condition (or a separate scoped user) in aws-infrastructure —
don't create IAM users out-of-band. If the key is rotated there, rerun the
block above (replace the old lines) and restart Grafana.

Test: Grafana → Alerting → Contact points → `email-alerts` → **Test**, or

```bash
curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:3000/api/alertmanager/grafana/config/api/v1/receivers/test \
  -d '{"receivers":[{"name":"email-alerts","grafana_managed_receiver_configs":[{"uid":"email_alerts","name":"email-alerts","type":"email","settings":{"addresses":"'"$ALERT_EMAIL_TO"'","singleEmail":true}}]}]}'
```

## Future slices (deferred)

- node_exporter for workstation metrics.
- Hermes dashboard `/api/metrics` (basic-auth).
- Postgres exporter for the litellm db.
- GeoIP enrichment of fail2ban IPs (Promtail `geoip` stage, needs a MaxMind key).
