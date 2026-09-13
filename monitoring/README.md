# monitoring/ — observability stack (Prometheus, Grafana, Loki, Promtail, blackbox)

A podman compose stack (pod `pod_monitoring`) running on the host. Manage it
directly with `podman-compose <args>` from this directory; secrets live in
`monitoring/.env` (git-ignored, auto-loaded by podman-compose — template in
`.env.example`).

## Components

| Service | Image | Port | Notes |
|---|---|---|---|
| **Prometheus** | `prom/prometheus:v2.53.1` | `127.0.0.1:9090` | 30d retention. Scrapes LiteLLM `/metrics/`, blackbox probes, Loki, Promtail, Traefik, itself. Runs as `user: "0"` (see [Troubleshooting](#troubleshooting)). No rule files — alerting is Grafana. |
| **blackbox_exporter** | `prom/blackbox-exporter:v0.25.0` | `127.0.0.1:9115` | HTTP probes of LiteLLM `/health/readiness` + `/health/liveliness` (no auth) — the uptime signal. Config `blackbox.yml`. |
| **Grafana** | `grafana/grafana-oss:11.2.0` | `127.0.0.1:3000` | Public at `https://grafana.chadrbean.com` via traefik (fail2ban middleware only). Own admin login. Unified alerting → email via Amazon SES SMTP. |
| **Loki** | `grafana/loki:3.1.1` | `127.0.0.1:3100` | Single-binary, filesystem store, 7d retention. Receives logs from Promtail. |
| **Promtail** | `promtail-linux-amd64:3.1.1` | `127.0.0.1:9190` | **Native systemd user service** (not containerized — see `promtail/README.md`). Tails fail2ban, Traefik, LiteLLM and Kopia logs. |

All use `network_mode: host` so they can reach host services directly (same
pattern as `traefik/`). Architecture diagram: [`docs/architecture.drawio`](../docs/architecture.drawio).

## Topology

```
                         /metrics/ (bearer)
LiteLLM :4000 ◀──────────────────────────────────── Prometheus :9090
   │  ▲  /health/readiness, /health/liveliness            │ ▲ ▲ ▲
   │  └───────────── blackbox :9115 ◀── /probe ───────────┘ │ │ │
   │ stdout tee (json_logs)                                  │ │ │ scrape
   ▼                                                         │ │ │
litellm_logs/proxy.log ──┐                                   │ │ │
fail2ban.log ────────────┤                                   │ │ │
traefik access.log ──────┼──▶ Promtail :9190 ────────────────┘ │ │
kopia cli-logs ──────────┘        │ push                       │ │
                                  ▼                            │ │
                              Loki :3100 ──────────────────────┘ │
                                  ▲ LogQL          PromQL        │
                                  └──────── Grafana :3000 ───────┘
                                                │ SMTP :587 (STARTTLS)
                                                ▼
                                   Amazon SES (us-west-1) ──▶ alert email
```

## Files

```
monitoring/
├── docker-compose.yml             # loki, prometheus, blackbox, grafana
├── prometheus.yml                 # scrape jobs (litellm, litellm-health, blackbox, traefik, loki, promtail)
├── blackbox.yml                   # blackbox_exporter http_2xx module
├── prometheus/
│   └── bearer_token               # git-ignored; LiteLLM scrape auth (scripts/refresh_bearer_token.sh)
├── loki-config.yaml               # single-binary, 7d retention
├── promtail/
│   ├── README.md                  # native-install reasoning
│   ├── promtail-config.yaml       # scrape jobs, drop stages, log-derived counters
│   └── promtail.service           # systemd user unit
├── logrotate/
│   ├── litellm-proxy.logrotate    # size 50M, keep 5, copytruncate
│   ├── litellm-logrotate.service  # systemd user oneshot
│   └── litellm-logrotate.timer    # hourly
├── dashboards/                    # GIT-TRACKED dashboards (Grafana folder "LiteLLM")
│   └── litellm-gateway.json
├── provisioning/
│   ├── dashboards/dashboards.yml  # providers: data/dashboards (runtime) + dashboards/ (tracked)
│   ├── datasources/
│   │   ├── prometheus.yml         # uid: prometheus
│   │   └── loki.yml               # uid: loki
│   └── alerting/
│       ├── notifications.yml      # contact point email-chad + root policy
│       ├── litellm-alerts.yml     # LiteLLM + collector rules (PromQL)
│       └── log-alerts.yml         # fail2ban + Kopia rules (LogQL)
└── data/dashboards/               # git-ignored, runtime dashboard JSON (fail2ban, kopia)
```

## Manage

```bash
podman-compose config                                   # validate compose
podman-compose up -d                                     # start everything
podman-compose up -d --force-recreate --no-deps grafana  # apply a compose/env change to one service
podman ps --format "{{.Names}}\t{{.Status}}"            # status (podman-compose ps is unreliable)
podman exec monitoring_prometheus kill -HUP 1            # reload prometheus.yml without restart
```

Native pieces:
```bash
systemctl --user status promtail                 # log shipper
systemctl --user restart promtail
journalctl --user -u promtail -f
systemctl --user list-timers litellm-logrotate   # proxy.log rotation
```

Install the logrotate timer (once):
```bash
cp logrotate/litellm-logrotate.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now litellm-logrotate.timer
```

## LiteLLM logging & metrics policy

Set in `../litellm/litellm-config.yaml` (and `LITELLM_LOG=INFO` in its compose):

| Setting | Why |
|---|---|
| `callbacks: [prometheus]`, `service_callback: [prometheus_system]` | Request/model/key/cost metrics + Postgres/Redis latency & failures |
| `json_logs: true` | Structured lines Promtail can label (`level`) |
| `turn_off_message_logging: true`, `redact_user_api_key_info: true` | **Metadata only** — prompt/response text never reaches logs or callbacks (bank/tax data) |
| `store_prompts_in_spend_logs: false`, `maximum_spend_logs_retention_period: 30d` | Spend rows keep cost/tokens only and are auto-pruned |
| `background_health_checks: true`, `health_check_interval: 900` | Keeps `litellm_deployment_state` fresh without traffic (one tiny call per model / 15 min) |

Promtail's `litellm` job drops `/health/*` and `/metrics` access lines and
exports three log-derived counters on `:9190`:
`promtail_custom_litellm_classifier_failures_total`,
`promtail_custom_litellm_secrets_redacted_total`,
`promtail_custom_litellm_log_errors_total`.

## Dashboard — LiteLLM Gateway

`dashboards/litellm-gateway.json` (uid `litellm-gateway`, folder **LiteLLM**).
Edit the JSON in git — UI saves are rejected (`allowUiUpdates: false`).
Variables: `model`, `key_alias`.

| Row | Panels |
|---|---|
| At a glance | Gateway UP/DOWN · Metrics scrape · Requests · Error rate · p95 latency · Spend · In-flight · Cache hit % |
| Traffic & errors | Requests/s by model · Failures by exception class · Responses by status code · Per-model success/requests/spend table |
| Latency | End-to-end p50/p95/p99 · Provider API p95 by model · TTFT p95 · Gateway overhead (+guardrails) · Queue time |
| Providers & routing | Deployment health state timeline · Upstream failures by provider · Fallbacks · Cooldowns · Smart-router classifier failures |
| Cost & tokens | Spend $/h by model · Tokens/s (input/output/reasoning/cached) · Spend by key · Remaining key budget · Cost per 1k requests · Budget hours left |
| Cache & guardrails | Cache hits vs misses · Provider cache-read tokens · Guardrail runs · Secrets redacted/h |
| Backend health | Postgres/Redis latency p95 & failures · Spend-update queues |
| Logs | Log lines by level · Warnings & errors (Loki) |

**Verify every widget** (run some traffic first, e.g. `scripts/smoke_test.py`):
```bash
./scripts/verify_dashboard.py --alerts            # PASS / WARN / FAIL per panel query + alert-rule health
./scripts/verify_dashboard.py --from now-1h
```
It runs each query through Grafana `/api/ds/query`, checks referenced metric
names exist in Prometheus, and exits 1 on any FAIL. Panels whose description
says "Empty is normal" (fallbacks, cooldowns, TTFT, …) only WARN when empty.

## Alerting

Single engine: **Grafana unified alerting**, provisioned from
`provisioning/alerting/`, every rule routed to contact point `email-chad`
(`notifications.yml`: group by folder+alertname, 30s wait, 4h repeat, resolved
emails on). There is no Alertmanager; the old `prometheus/alerts.yml` was
removed because nothing ever received its alerts.

| Rule | Condition | For | Severity |
|---|---|---|---|
| **LiteLLM Gateway Down** | `min(probe_success{job="litellm-health"}) < 1` (no data ⇒ firing) | 2m | critical |
| LiteLLM Metrics Scrape Failing | `up{job="litellm"} < 1` | 5m | warning |
| LiteLLM High Error Rate | failed/total LLM requests > 10% over 10m (with traffic) | 10m | warning |
| LiteLLM Provider Outage | `litellm_deployment_state >= 2` per model | 5m | critical |
| LiteLLM Slow Responses | p95 end-to-end latency > 30s | 10m | warning |
| LiteLLM Key Budget Low | remaining key budget < $5 | 15m | warning |
| Smart Router Classifier Failing | > 5 classifier failures in 15m | 0 | warning |
| Promtail Down / Loki Down | `up < 1` | 1m | critical |
| Promtail Dropping Logs | dropped entries in 10m > 0 | 5m | warning |
| Fail2ban Ban Spike / High Ban Rate | LogQL ban counts | 2m / 5m | warning / critical |
| Kopia Backup Stale / Warning | no Kopia INFO lines in 26h / 20h | 10m | critical / warning |

UI: `https://grafana.chadrbean.com/alerting/list`.

### Alert email (Amazon SES SMTP)

Grafana sends through `email-smtp.us-west-1.amazonaws.com:587` (STARTTLS) as
`grafana@chadrbean.com` (domain verified with DKIM). While SES is in the
sandbox, `GRAFANA_ALERT_EMAIL` must be a verified identity (200 mails/day).

SMTP credentials come from a dedicated IAM user that can only send mail:

```bash
aws iam create-user --user-name grafana-ses-smtp
aws iam put-user-policy --user-name grafana-ses-smtp --policy-name ses-send-only --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Action": "ses:SendRawEmail", "Resource": "*",
                 "Condition": {"StringEquals": {"ses:FromAddress": "grafana@chadrbean.com"}}}]}'
aws iam create-access-key --user-name grafana-ses-smtp   # -> AccessKeyId / SecretAccessKey
```

The SMTP username is the AccessKeyId; the SMTP **password is derived** from the
SecretAccessKey (AWS SigV4 algorithm, region-specific):

```python
import hmac, hashlib, base64
def ses_smtp_password(secret, region="us-west-1"):
    sig = hmac.new(("AWS4" + secret).encode(), b"11111111", hashlib.sha256).digest()
    for msg in (region, "ses", "aws4_request", "SendRawEmail"):
        sig = hmac.new(sig, msg.encode(), hashlib.sha256).digest()
    return base64.b64encode(b"\x04" + sig).decode()
```

Put `GRAFANA_SMTP_ENABLED=true`, `GRAFANA_SMTP_USER`, `GRAFANA_SMTP_PASSWORD`,
`GRAFANA_ALERT_EMAIL` in `monitoring/.env`, then
`podman-compose up -d --force-recreate --no-deps grafana`. Test delivery from
Grafana → Alerting → Contact points → `email-chad` → **Test**.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `litellm` target DOWN: `unable to read file /etc/prometheus/litellm_bearer_token` | Container not running as `user: "0"`. In rootless podman the 600 host file shows as root-owned; the image default `nobody` can't read it. |
| `litellm` target DOWN: 401 | Master key rotated — `../scripts/refresh_bearer_token.sh`, then restart prometheus. |
| Dashboard panels "No data" but targets up | `./scripts/verify_dashboard.py` — look for `unknown metric` (LiteLLM renamed a metric) vs `no data` (no traffic yet). |
| Alerts show firing but no email | Grafana logs `Notify for alerts failed` → check `GF_SMTP_*` / SES sandbox recipient verification. |
| `{job="litellm"}` empty in Loki | `systemctl --user status promtail`; confirm `proxy.log` path in the volume (`podman volume inspect litellm_logs`). |

## Future slices (deferred)

- node_exporter for workstation metrics.
- Hermes dashboard `/api/metrics` (basic-auth).
- Postgres exporter for the litellm db.
