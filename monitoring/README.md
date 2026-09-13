# monitoring/ — observability stack (Prometheus, Grafana, Loki, Promtail)

A podman compose stack (pod `pod_monitoring`) running on the host. Manage it
directly with `podman-compose <args>` from this directory; secrets live in
`monitoring/.env` (git-ignored, auto-loaded by podman-compose).

## Components

| Service | Image | Port | Notes |
|---|---|---|---|
| **Prometheus** | `prom/prometheus:v2.53.1` | `127.0.0.1:9090` | 30d retention. Scrapes LiteLLM, itself, Loki, Promtail. |
| **Grafana** | `grafana/grafana-oss:11.2.0` | `127.0.0.1:3000` | Public at `https://grafana.chadrbean.com` via traefik (fail2ban middleware only). Own admin login from `monitoring/.env`. |
| **Loki** | `grafana/loki:3.1.1` | `127.0.0.1:3100` | Single-binary, filesystem store, 7d retention. Receives logs from Promtail. |
| **Promtail** | `promtail-linux-amd64:3.1.1` | `127.0.0.1:9190` | **Native systemd user service** (not containerized — see `promtail/README.md`). Tails fail2ban + Kopia logs. |

All four use `network_mode: host` so they can reach host services directly
(same pattern as `traefik/`).

## Scrape topology

```
                     /metrics/         (bearer)
LiteLLM :4000 ──────────────────────────────────┐
                                                ▼
fail2ban.log ──┐                          Prometheus :9090
               │                                ▲
kopia logs ────┴──▶ Promtail :9190 ──────────► │
                       │                        │
                       │  HTTP push             │ scrape
                       ▼                        │
                   Loki :3100 ──────────────────┘
                        ▲
                        │ LogQL
                        ▼
                Grafana :3000
```

## Files

```
monitoring/
├── docker-compose.yml             # 3 services: loki, prometheus, grafana
├── prometheus.yml                 # scrape jobs + rule_files
├── prometheus/
│   ├── bearer_token               # git-ignored; LiteLLM scrape auth
│   └── alerts.yml                 # Prometheus rules (collector health)
├── loki-config.yaml               # single-binary, 7d retention
├── promtail/
│   ├── README.md                  # native-install reasoning
│   ├── promtail-config.yaml       # scrape jobs + drop-stage
│   └── promtail.service           # systemd user unit
├── provisioning/
│   ├── dashboards/dashboards.yml  # file provider
│   ├── datasources/
│   │   ├── prometheus.yml
│   │   └── loki.yml
│   └── alerting/
│       └── log-alerts.yml         # Grafana LogQL rules
└── data/dashboards/               # git-ignored, runtime dashboard JSON
    ├── fail2ban.json
    ├── kopia.json
    └── litellm-prod-v2.json
```

## Manage

```bash
podman-compose config                          # validate compose
podman-compose up -d                            # start all 3 services
podman-compose up -d loki                       # start one
podman ps --format "{{.Names}}\t{{.Status}}"   # status (podman-compose ps is unreliable)
```

Promtail (native) is managed separately:
```bash
systemctl --user status promtail
systemctl --user restart promtail
journalctl --user -u promtail -f
```

## Alerting

Two layers, divided by what each tool can natively observe:

- **Prometheus rules** (`prometheus/alerts.yml`) — collector health.
  `PromtailDown`, `LokiDown`, `PromtailHighIngestionErrors`. Surface in
  Prometheus UI at `:9090/alerts`.
- **Grafana rules** (`provisioning/alerting/log-alerts.yml`) — log conditions.
  `Fail2ban Ban Spike`, `Fail2ban High Ban Rate`, `Kopia Backup Stale`,
  `Kopia Backup Warning`. Surface in Grafana at
  `https://grafana.chadrbean.com/alerting/list`.

Alertmanager is not yet wired (deferred slice). Both surfaces can be
inspected manually until then.

## Future slices (deferred)

- Alertmanager (so Prometheus alerts have a destination).
- node_exporter for workstation metrics.
- Hermes dashboard `/api/metrics` (basic-auth).
- Postgres exporter for the litellm db.