# monitoring/ — observability stack (Prometheus, Grafana, Loki, Promtail)

A podman compose stack (pod `pod_monitoring`) running on the host. Manage it
directly with `podman-compose <args>` from this directory; secrets live in
`monitoring/.env` (git-ignored, auto-loaded by podman-compose — template in
`.env.example`). Architecture diagram: [`../docs/monitoring.drawio`](../docs/monitoring.drawio).

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

Grafana sends through Amazon SES SMTP in `us-west-1` (`chadrbean.com` is
DKIM-verified, so any `@chadrbean.com` sender works). SES **SMTP credentials
are not the AWS access key** — create a dedicated IAM user once:

```bash
aws iam create-user --user-name ses-smtp-grafana
aws iam put-user-policy --user-name ses-smtp-grafana --policy-name ses-send \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"ses:SendRawEmail","Resource":"*"}]}'
aws iam create-access-key --user-name ses-smtp-grafana   # -> AccessKeyId + SecretAccessKey
```

Derive the SMTP password from the secret key (AWS's documented algorithm,
region-specific):

```bash
python3 - <<'EOF'
import hmac, hashlib, base64, getpass
secret = getpass.getpass("SecretAccessKey: ")
def sign(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
sig = sign(("AWS4" + secret).encode(), "11111111")
for part in ("us-west-1", "ses", "aws4_request", "SendRawEmail"):
    sig = sign(sig, part)
print(base64.b64encode(bytes([0x04]) + sig).decode())
EOF
```

Then in `monitoring/.env`: `GRAFANA_SMTP_USER=<AccessKeyId>`,
`GRAFANA_SMTP_PASSWORD=<derived password>`, `ALERT_EMAIL_TO=<you>`, and
`podman-compose up -d grafana`. The account is in the **SES sandbox**:
`ALERT_EMAIL_TO` must be a verified identity in `us-west-1`
(`aws sesv2 get-email-identity --email-identity <addr> --region us-west-1`).

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
