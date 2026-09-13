# LiteLLM Observability — metrics, logs, dashboard, alerting

The record of the 2026-09-12 LiteLLM observability overhaul: what was broken, what the
policies are, how it is wired, how to roll it out and how to prove it works.
Component reference lives in [`monitoring/README.md`](../monitoring/README.md); the
diagram is [`docs/architecture.drawio`](architecture.drawio). PR: chadrbean/localsetup#2.

**Status:** code merged-ready in PR #2; static checks pass. **Live rollout + end-to-end
verification pending** — see [Rollout](#rollout) and [Verification log](#verification-log).

---

## 1. What was found (investigation 2026-09-12)

| # | Problem | Root cause | Fix |
|---|---|---|---|
| 1 | Prometheus `litellm` target DOWN since 2026-09-11 20:49 — dashboard silently stale | `monitoring/prometheus/bearer_token` is `chmod 600`, owned by host uid 1000 = uid 0 inside rootless podman; the Prometheus image runs as `nobody` and can't read it | `user: "0"` on the prometheus service (no privilege gain in rootless podman); `authorization.credentials_file` |
| 2 | No alert was ever delivered (~235 failures / 12h) | Only contact point was Grafana's placeholder `<example@email.com>`; no `[smtp]`; Prometheus rules had no Alertmanager | Grafana is the single alert engine; email via Amazon SES SMTP; provisioned contact point + policy |
| 3 | "Kopia Backup Stale" permanently firing; "Fail2ban High Ban Rate" stuck NoData | LogQL `\| unwrap _` (parse error) and free-text `classic_conditions` | Rules rewritten: instant count `or vector(0)` + `math` condition |
| 4 | Every `smart` request fell back to the heuristic scorer (195 `LLM classifier failed`) | Slim `litellm-config.yaml` dropped `or-lite-deepseek-flash`, which the classifier still referenced; all fallbacks dropped too | Model restored; fallback net `smart`/`or-lite-*` → `flash` |
| 5 | LiteLLM logs not searchable | Not shipped to Loki; `proxy.log` 14 MB, unrotated, colored plain text; ~83% noise (39k secret-redaction warnings, 17k `/metrics`, 9.6k `/health/liveliness` lines) | `json_logs`, Promtail `litellm` job with drop stages, logrotate timer |
| 6 | Dashboard thin / partly broken | Upstream "LiteLLM Prod v2" (7 panels, git-ignored); 2 panels used renamed metrics `litellm_remaining_requests/tokens` | Tracked 37-panel **LiteLLM Gateway** dashboard + `scripts/verify_dashboard.py` |

Healthy at the time: LiteLLM 1.99.1, `/health/readiness` healthy with DB connected,
`/metrics/` exposing ~60 metric families, Promtail/Loki/Traefik targets up.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Alert delivery | Grafana native email via **SES SMTP**, dedicated send-only IAM user | No extra relay service to keep alive; reuses verified `chadrbean.com` SES domain |
| Canonical LiteLLM config | **Slim** `litellm-config.yaml`, references fixed | `litellm-config_heavy.yaml` kept as reference for the full ladder |
| Log content | **Metadata only** | Gateway carries bank statements / tax data — prompt text must never reach logs or spend rows |
| Alert engine | Grafana unified alerting only | It is the only engine with a notification path; removed `prometheus/alerts.yml` |
| Uptime signal | blackbox probe of unauthenticated `/health/readiness` + `/health/liveliness` | Independent of the bearer-token scrape; readiness returns 503 if Postgres is down |

## 3. LiteLLM configuration policy

`litellm/litellm-config.yaml`:

```yaml
litellm_settings:
  callbacks: [prometheus]              # request/model/key/cost/latency metrics on /metrics/
  service_callback: [prometheus_system] # postgres/redis/router latency + failures
  json_logs: true                      # structured stdout -> proxy.log -> Promtail
  turn_off_message_logging: true       # no prompt/response text to any callback
  redact_user_api_key_info: true
  num_retries: 0                       # fail fast into the fallback net
  request_timeout: 45

router_settings:
  fallbacks:
    - smart: ["flash"]
    - or-lite-deepseek-flash: ["flash"]
    - or-lite-qwen: ["flash"]
    - or-lite-glm: ["flash"]
  allowed_fails: 3
  cooldown_time: 60

general_settings:
  store_prompts_in_spend_logs: false
  maximum_spend_logs_retention_period: "30d"
  background_health_checks: true       # keeps litellm_deployment_state fresh
  health_check_interval: 900           # one tiny real call per model / 15 min
  health_check_details: false
```

`litellm/docker-compose.yml` sets `LITELLM_LOG: INFO` (the code default is DEBUG).

**What each block does:**
- `callbacks: [prometheus]` enables the per-request metrics that feed the dashboard
  (open source since LiteLLM v1.80; `/metrics/` requires the master key since ~v1.84).
  `prometheus_system` adds backend health (`litellm_postgres_*`, `litellm_redis_*`).
- `turn_off_message_logging` stops message bodies reaching *any* logging callback while
  still emitting model, tokens, cost, latency, status and key alias — the privacy policy.
- The fallback net routes every OpenRouter tier to the native DeepSeek spine, an
  independent endpoint, so one provider block can't take `smart` down. `allowed_fails` /
  `cooldown_time` bench a failing deployment for 60s after 3 failures.
- `background_health_checks` makes LiteLLM probe each model on a schedule so the
  "Deployment health" panel and "Provider Outage" alert work even when idle. Use
  `/health/readiness` (free) for uptime, never poll `/health` (it calls every model).

## 4. Logs pipeline

```
LiteLLM stdout ──tee──▶ litellm_logs volume: proxy.log ──▶ Promtail (job=litellm) ──▶ Loki (7d)
                         └─ litellm-logrotate.timer (hourly, 50M, keep 5, copytruncate)
```

Promtail `litellm` job (`monitoring/promtail/promtail-config.yaml`):
- **Drops** `GET /health/liveliness|readiness` and `GET /metrics` access lines.
- **Labels** `level` only (no `trace_id` — unbounded cardinality).
- **Log-derived counters** on `:9190`: `promtail_custom_litellm_classifier_failures_total`,
  `promtail_custom_litellm_secrets_redacted_total`, `promtail_custom_litellm_log_errors_total`.

Useful LogQL:
```logql
{job="litellm", level=~"(?i)error"}                                  # errors
sum by (level) (count_over_time({job="litellm"}[5m]))                # volume by level
{job="litellm"} |= "LLM classifier failed"                            # smart router degradation
```

## 5. Dashboard — LiteLLM Gateway

`monitoring/dashboards/litellm-gateway.json` (uid `litellm-gateway`, Grafana folder
**LiteLLM**, git-tracked, UI edits rejected). Variables `model`, `key_alias`. LLM-traffic
panels filter `requested_model!=""` so admin/UI routes (e.g. `/v1/models/<name>` 401s)
don't pollute error rates.

| Row | Panels |
|---|---|
| At a glance | Gateway UP/DOWN · Metrics scrape · Requests · Error rate · p95 latency · Spend · In-flight · Cache hit % |
| Traffic & errors | Requests/s by model · Failures by exception class · Responses by status · Per-model success / requests / spend |
| Latency | p50/p95/p99 · Provider API p95 · Time-to-first-token p95 · Gateway overhead (+guardrails) · Queue time |
| Providers & routing | Deployment health timeline · Upstream failures by provider · Fallbacks · Cooldowns · Classifier failures/h |
| Cost & tokens | Spend $/h by model · Tokens/s · Spend by key · Remaining key budget · Cost / 1k requests · Budget hours left |
| Cache & guardrails | Cache hits vs misses · Provider cache-read tokens · Guardrail runs · Secrets redacted/h |
| Backend health | Postgres/Redis p95 latency & failures · Spend-update queues |
| Logs | Log lines by level · Warnings & errors |

**Test every widget:**
```bash
set -a; . litellm/.env; set +a
LITELLM_MODELS="flash smart or-lite-qwen" .venv/bin/python scripts/smoke_test.py   # generate traffic
./scripts/verify_dashboard.py --alerts --from now-1h
```
`verify_dashboard.py` runs each panel query through Grafana `/api/ds/query`, fails on query
errors, unknown metric names (renamed upstream) or empty results, and reports alert-rule
health. Panels whose description says "Empty is normal" (fallbacks, cooldowns, TTFT, …)
only WARN when empty. Exit code 1 on any FAIL.

## 6. Service monitoring & alerting

Rules: `monitoring/provisioning/alerting/{litellm-alerts,log-alerts}.yml`; routing:
`notifications.yml` (contact point `email-chad` ← `GRAFANA_ALERT_EMAIL`; group by
folder+alertname, 30s wait, 5m interval, 4h repeat, resolved emails on).

| Rule | Condition | For | Severity |
|---|---|---|---|
| **LiteLLM Gateway Down** | `min(probe_success{job="litellm-health"}) < 1`; no data ⇒ firing | 2m | critical |
| LiteLLM Metrics Scrape Failing | `max(up{job="litellm"}) < 1` | 5m | warning |
| LiteLLM High Error Rate | failed/total LLM requests > 10% over 10m, only with traffic | 10m | warning |
| LiteLLM Provider Outage | `max by (litellm_model_name, api_provider) (litellm_deployment_state) >= 2` | 5m | critical |
| LiteLLM Slow Responses | p95 end-to-end latency > 30s | 10m | warning |
| LiteLLM Key Budget Low | remaining key budget < $5 | 15m | warning |
| Smart Router Classifier Failing | > 5 classifier failures / 15m | 0 | warning |
| Promtail Down · Loki Down | `up < 1` | 1m | critical |
| Promtail Dropping Logs | `increase(promtail_dropped_entries_total[10m]) > 0` | 5m | warning |
| Fail2ban Ban Spike · High Ban Rate | LogQL ban counts | 2m / 5m | warning / critical |
| Kopia Backup Stale · Warning | no Kopia INFO lines in 26h / 20h | 10m | critical / warning |

### Email via Amazon SES SMTP

- Relay `email-smtp.us-west-2.amazonaws.com:587` STARTTLS, from `grafana@chadrbean.com`.
- SES account is in the **sandbox**: recipient must be a verified identity, 200 mails/day.
- Credentials: IAM user `grafana-ses-smtp` with only `ses:SendRawEmail` conditioned on
  `ses:FromAddress = grafana@chadrbean.com`. SMTP username = its AccessKeyId; SMTP password
  is **derived** from the SecretAccessKey (algorithm in `monitoring/README.md` → "Alert email").
- `monitoring/.env`: `GRAFANA_SMTP_ENABLED=true`, `GRAFANA_SMTP_USER`, `GRAFANA_SMTP_PASSWORD`,
  `GRAFANA_ALERT_EMAIL`. Apply with `podman-compose up -d --force-recreate --no-deps grafana`.

## Rollout

One-time steps to take it live on this host (all from `~/git/localsetup`). After
pulling the merged code, **steps 2–7 are automated** by
`./scripts/rollout_observability.sh` (idempotent; archives `proxy.log` only on first run,
checks `.env`, installs the timer, recreates services, prints scrape-target health):

```bash
cd ~/git/localsetup
git fetch origin
git diff origin/main --stat      # only files from PR #2 should differ; anything else = local edits to keep
git reset --hard origin/main     # safe for .env/bearer_token (git-ignored); commit/stash other edits first
./scripts/rollout_observability.sh
```

Manual equivalent:

1. **Sync files** — merge PR #2 and pull it into the checkout.
2. **Env** — add `GRAFANA_ALERT_EMAIL=<verified address>` and `GRAFANA_SMTP_ENABLED=false`
   (until SES creds exist) to `monitoring/.env`; compose refuses to start Grafana without
   `GRAFANA_ALERT_EMAIL`.
3. **Archive the old log** so Promtail doesn't ingest pre-JSON history:
   ```bash
   LOG=~/.local/share/containers/storage/volumes/litellm_logs/_data/proxy.log
   gzip -c "$LOG" > "$LOG.pre-json-$(date +%F).gz" && : > "$LOG"
   ```
4. **Logrotate timer**:
   ```bash
   cp monitoring/logrotate/litellm-logrotate.{service,timer} ~/.config/systemd/user/
   systemctl --user daemon-reload && systemctl --user enable --now litellm-logrotate.timer
   ```
5. **Retire the old dashboard**: move `monitoring/data/dashboards/litellm-prod-v2.json` out.
6. **Restart LiteLLM** (≈20–60s gateway downtime):
   ```bash
   cd litellm && podman-compose up -d --force-recreate --no-deps litellm
   curl -s localhost:4000/health/readiness
   ```
7. **Restart monitoring + Promtail**:
   ```bash
   cd ../monitoring && podman-compose up -d --force-recreate --no-deps prometheus blackbox grafana
   systemctl --user restart promtail
   ```
8. **SES SMTP** — create the IAM user and credentials (section 6), set
   `GRAFANA_SMTP_ENABLED=true`, recreate Grafana.

## Verification checklist

| Check | Command / how | Expect |
|---|---|---|
| Targets up | `curl -s 127.0.0.1:9090/api/v1/targets` | `litellm`, `litellm-health` ×2, `blackbox`, `promtail`, `loki`, `traefik` all `up` |
| Classifier fixed | `/v1/models` includes `or-lite-deepseek-flash`; a `smart` request | no new `LLM classifier failed` lines |
| JSON logs in Loki | `curl -s 127.0.0.1:3100/loki/api/v1/label/job/values` | includes `litellm`; `level` label present |
| **Privacy** | send a prompt containing `ZZPRIVACYCANARY123`; search Loki `{job="litellm"} \|= "ZZPRIVACYCANARY123"` and `SELECT count(*) FROM "LiteLLM_SpendLogs" WHERE messages::text LIKE '%ZZPRIVACYCANARY123%'` | 0 hits in both |
| Dashboard | `./scripts/verify_dashboard.py --alerts` after smoke traffic | no FAIL |
| Email path | Grafana → Alerting → Contact points → `email-chad` → Test | email arrives |
| Gateway-down alert | `podman stop litellm_litellm_1` ~3 min, then `podman start` | "LiteLLM Gateway Down" firing email, then resolved email |
| Kopia/fail2ban rules | `verify_dashboard.py --alerts` | `health=ok` (no parse errors) |

## Verification log

| Date | Check | Result |
|---|---|---|
| 2026-09-12 | `promtool check config`, `promtail -check-syntax`, `blackbox_exporter --config.check`, YAML parse, `py_compile verify_dashboard.py` | PASS |
| — | Live rollout (steps 1–7) | _pending_ |
| — | SES SMTP credentials (step 8) | _pending_ |
| — | Checklist above | _pending_ |

## Operational notes

- **Master key rotation** → `scripts/refresh_bearer_token.sh`, then
  `podman restart monitoring_prometheus`; otherwise "LiteLLM Metrics Scrape Failing" fires.
- **Adding a model** to `litellm-config.yaml` needs no dashboard change (panels group by
  label). If it's a new OpenRouter tier, add it to `router_settings.fallbacks`.
- **Changing the classifier model** — it must exist in `model_list`, or
  "Smart Router Classifier Failing" fires.
- **LiteLLM upgrade** — run `verify_dashboard.py`; `unknown metric` results mean upstream
  renamed a metric.
