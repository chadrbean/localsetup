# LiteLLM Observability — metrics, logs, dashboard, alerting

What was broken, the policies, how it's wired, how to roll it out, and how to prove it works.
The overhaul was investigated on 2026-09-12 and shipped in PR #2. It builds on the shared
monitoring stack from PR #3 (see [SECURITY-MONITORING.md](SECURITY-MONITORING.md): alert
email, contact point, collector health rules, fail2ban/Traefik/Kopia).

- Component reference: [`monitoring/README.md`](../monitoring/README.md)
- Diagram: [`docs/monitoring.drawio`](monitoring.drawio)

**Status:** merged. **Live rollout and end-to-end verification are pending** (user deploys). See
[Rollout](#rollout) and [Verification log](#verification-log).

---

## 1. What was found (investigation 2026-09-12)

| # | Problem | Root cause | Fix |
|---|---|---|---|
| 1 | Prometheus `litellm` target DOWN since 2026-09-11 20:49, so the dashboard was silently stale | `bearer_token` is `chmod 600`. In rootless podman the Prometheus container runs as `nobody` and can't read it | `user: "0:0"` on Prometheus (landed via PR #3) |
| 2 | No alert was ever delivered (~235 failures in 12h) | The only contact point was the placeholder `<example@email.com>`, with no SMTP configured | PR #3: `contact-points.yml` + SES SMTP (`hermes-ses-email`) |
| 3 | "Kopia Backup Stale" permanently firing | LogQL `\| unwrap _` and free-text `classic_conditions` | PR #3: rules rewritten (reduce → threshold) |
| 4 | Every `smart` request fell back to the heuristic scorer (195 `LLM classifier failed`) | The slim `litellm-config.yaml` dropped `or-lite-deepseek-flash`, which the classifier still referenced. All fallbacks were dropped too | Model restored; fallback net `smart`/`or-lite-*` → `flash` |
| 5 | LiteLLM logs not searchable | Not shipped to Loki. `proxy.log` was 14 MB, never rotated, and ~83% noise (secret-redaction warnings, `/metrics`, `/health` lines) | `json_logs`, Promtail `litellm` job with drop stages, logrotate timer |
| 6 | Dashboard thin and partly broken | Upstream "LiteLLM Prod v2": 7 panels, git-ignored, 2 panels used renamed metrics | Tracked 37-panel **LiteLLM Gateway** dashboard + `scripts/verify_dashboard.py` |
| 7 | No LiteLLM uptime signal independent of the bearer-token scrape | — | blackbox probes of `/health/readiness` + `/health/liveliness` → **LiteLLM Gateway Down** |

Items 1–3 were found independently by both PRs. PR #3's implementation is the one kept.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Alert delivery | Shared Grafana email path from PR #3 (`contact-points.yml`, SES us-west-2, Terraform `hermes-ses-email`, sender `hermes@chadrbean.com`) | One notification policy per Grafana org. Don't create IAM users out-of-band |
| AWS region | **us-west-2 only**, no SES in us-west-1 | User decision 2026-09-12; SES identities live in us-west-2 |
| Canonical LiteLLM config | **Slim** `litellm-config.yaml`, references fixed | `litellm-config_heavy.yaml` kept as reference for the full ladder |
| Log content | **Metadata only** | The gateway carries bank statements and tax data, so prompt text must never reach logs or spend rows |
| Uptime signal | blackbox probe of the unauthenticated health endpoints | Independent of the bearer token. Readiness returns 503 if Postgres is down |

## 3. LiteLLM configuration policy

`litellm/litellm-config.yaml`:

```yaml
litellm_settings:
  callbacks: [prometheus]               # request/model/key/cost/latency metrics on /metrics/
  service_callback: [prometheus_system] # postgres/redis/router latency + failures
  json_logs: true                       # structured stdout -> proxy.log -> Promtail
  turn_off_message_logging: true        # no prompt/response text to any callback
  redact_user_api_key_info: true
  num_retries: 0                        # fail fast into the fallback net
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
  background_health_checks: true        # keeps litellm_deployment_state fresh
  health_check_interval: 900            # one tiny real call per model / 15 min
  health_check_details: false
```

`litellm/docker-compose.yml` sets `LITELLM_LOG: INFO`; the code default is DEBUG.

**What each block does:**
- **`callbacks: [prometheus]`** enables the per-request metrics that feed the dashboard. It has been open source since LiteLLM v1.80; `/metrics/` has needed the master key since about v1.84.
- **`prometheus_system`** adds backend health metrics (`litellm_postgres_*`, `litellm_redis_*`).
- **`turn_off_message_logging`** stops message bodies from reaching *any* logging callback. Model, tokens, cost, latency, status and key alias still go out. This is the privacy policy.
- **The fallback net** sends every OpenRouter tier to the native DeepSeek spine, which is an independent endpoint, so one provider block can't take `smart` down.
- **`allowed_fails` / `cooldown_time`** bench a failing deployment for 60s after 3 failures.
- **`background_health_checks`** makes LiteLLM probe each model on a schedule, so the "Deployment health" panel and "Provider Outage" alert still work when there's no traffic.
- **Uptime checks:** use `/health/readiness`, which is free. Never poll `/health`, which calls every model.

## 4. Logs pipeline

```
LiteLLM stdout ──tee──▶ litellm_logs volume: proxy.log ──▶ Promtail (job=litellm) ──▶ Loki (7d)
                         └─ litellm-logrotate.timer (hourly, 50M, keep 5, copytruncate)
```

Promtail `litellm` job (`monitoring/promtail/promtail-config.yaml`):
- **Drops** `GET /health/liveliness|readiness` and `GET /metrics` access lines.
- **Labels** `level` only; trace ids stay in the line, per the cardinality rule in SECURITY-MONITORING §4.
- **Log-derived counters** on `:9190`:
  - `promtail_custom_litellm_classifier_failures_total`
  - `promtail_custom_litellm_secrets_redacted_total`
  - `promtail_custom_litellm_log_errors_total`

Useful LogQL:
```logql
{job="litellm", level=~"(?i)error"}                      # errors
sum by (level) (count_over_time({job="litellm"}[5m]))    # volume by level
{job="litellm"} |= "LLM classifier failed"               # smart router degradation
```

## 5. Dashboard — LiteLLM Gateway

`monitoring/dashboards/litellm-gateway.json`:
- uid `litellm-gateway`, at `/d/litellm-gateway`, in Grafana folder **Ops**
- tracked in git; UI edits are disabled
- datasource uid `PBFA97CFB590B2093`
- variables `model` and `key_alias`

LLM-traffic panels filter `requested_model!=""`, so admin and UI routes (e.g. `/v1/models/<name>` 401s) don't pollute error rates.

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
(set -a; . litellm/.env; set +a; LITELLM_MODELS="flash smart or-lite-qwen" .venv/bin/python scripts/smoke_test.py)
./scripts/verify_dashboard.py --alerts --from now-1h
```

`verify_dashboard.py` runs each panel query through Grafana `/api/ds/query` and reports alert-rule health.
- **FAIL:** query errors, unknown metric names (renamed upstream), or empty results. Exit code 1 on any FAIL.
- **WARN only when empty:** panels whose description says "Empty is normal" (fallbacks, cooldowns, TTFT, …).

## 6. Alerting

LiteLLM rules live in `monitoring/provisioning/alerting/litellm-alerts.yml` (folder **LiteLLM**). They route through the shared `contact-points.yml` (`email-alerts` → `$ALERT_EMAIL_TO`). Scrape and collector health, including **Scrape Target Down** for `job=litellm` and `job=blackbox`, are in `health-alerts.yml` ([SECURITY-MONITORING §6](SECURITY-MONITORING.md)).

| Rule | Condition | For | Severity |
|---|---|---|---|
| **LiteLLM Gateway Down** | `min(probe_success{job="litellm-health"}) or on() vector(0)` < 1 | 2m | critical |
| LiteLLM High Error Rate | failed/total LLM requests > 10% over 10m, only with traffic | 10m | warning |
| LiteLLM Provider Outage | `max by (litellm_model_name, api_provider) (litellm_deployment_state)` = 2 | 5m | critical |
| LiteLLM Slow Responses | p95 end-to-end latency > 30s | 10m | warning |
| LiteLLM Key Budget Low | remaining key budget < $5 | 15m | warning |
| Smart Router Classifier Failing | > 5 classifier failures in 15m | 0 | warning |

**Email:** SES SMTP in **us-west-2**, credentials from the Terraform-managed `hermes-ses-email` user, sender `hermes@chadrbean.com`. See SECURITY-MONITORING §7 for how to populate `monitoring/.env` (`GRAFANA_SMTP_*`, `ALERT_EMAIL_TO`).

## Rollout

The live services read config from `~/git/localsetup`. Do the shared PR #3 deploy first
([SECURITY-MONITORING §8](SECURITY-MONITORING.md): SMTP env, fail2ban sudo steps), then:

```bash
cd ~/git/localsetup
git fetch origin
git diff origin/main --stat      # only PR #2/#3 files should differ; anything else = local edits to keep
git reset --hard origin/main     # git-ignored .env / bearer_token / data/ survive
./scripts/rollout_observability.sh
```

`scripts/rollout_observability.sh` is idempotent. It:
1. **Preflight:** requires `ALERT_EMAIL_TO`, warns if `GRAFANA_SMTP_USER` is empty, and regenerates `bearer_token` if it's missing.
2. **Log archive:** archives and truncates the pre-JSON `proxy.log` (first run only, tracked by a marker file).
3. **Logrotate:** installs and enables `litellm-logrotate.timer`.
4. **Duplicate dashboards:** moves `monitoring/data/dashboards/{fail2ban,kopia,litellm-prod-v2}.json` aside, since their uids clash with tracked copies or retired dashboards.
5. **LiteLLM:** recreates `litellm` (about 20–60s of gateway downtime) and waits for readiness.
6. **Monitoring:** recreates `prometheus`, `blackbox` and `grafana`, then restarts Promtail.
7. **Report:** prints scrape-target health.

## Verification checklist

| Check | Command / how | Expect |
|---|---|---|
| Targets up | `curl -s 127.0.0.1:9090/api/v1/targets` | `litellm`, `litellm-health` ×2, `blackbox`, `promtail`, `loki`, `traefik`, `fail2ban` all `up` |
| Classifier fixed | `/v1/models` includes `or-lite-deepseek-flash`; send a `smart` request | no new `LLM classifier failed` lines |
| JSON logs in Loki | `curl -s 127.0.0.1:3100/loki/api/v1/label/job/values` | includes `litellm`; `level` label present |
| **Privacy** | Send a prompt containing `ZZPRIVACYCANARY123`. Search Loki with `{job="litellm"} \|= "ZZPRIVACYCANARY123"` and Postgres with `SELECT count(*) FROM "LiteLLM_SpendLogs" WHERE messages::text LIKE '%ZZPRIVACYCANARY123%'` | 0 hits in both |
| Dashboard | `./scripts/verify_dashboard.py --alerts` after smoke traffic | no FAIL |
| Email path | Grafana → Alerting → Contact points → `email-alerts` → Test | email arrives from `hermes@chadrbean.com` |
| Gateway-down alert | `podman stop litellm_litellm_1` for about 3 min, then `podman start` | "LiteLLM Gateway Down" firing email, then resolved email |

## Verification log

| Date | Check | Result |
|---|---|---|
| 2026-09-12 | `promtool check config`, `promtail -check-syntax`, `blackbox_exporter --config.check`, YAML/JSON parse, `py_compile verify_dashboard.py`, `bash -n rollout_observability.sh` | PASS (re-run after merging main incl. PR #3/#4/#5) |
| 2026-09-12 | Promtail `-stdin -dry-run` of the `litellm` job on sample lines | PASS — `/health/liveliness` + `/metrics/` lines dropped; JSON lines labeled `level=WARNING/ERROR`; plain access line shipped unlabeled |
| 2026-09-12 | Throwaway Grafana 11.2 (`127.0.0.1:3300`, SMTP off) with this branch's provisioning against live Prometheus/Loki, `verify_dashboard.py --alerts --from now-7d` | **20/20 alert rules `health=ok`** (6 LiteLLM + 14 shared). Panels: 57 pass, 6 warn (allowed empty), 9 fail — all pre-deploy gaps, none query errors: `probe_success` (blackbox not running), `promtail_custom_litellm_*` + `{job="litellm"}` logs (Promtail job not live), `litellm_postgres/redis_latency` (`prometheus_system` not enabled; names confirmed in LiteLLM 1.99.1 source), In-flight / key-budget gauges (no fresh samples — scrape down since 2026-09-11). Re-run after rollout; expect 0 fail |
| — | Live rollout | _pending (user deploys)_ |
| — | Checklist above | _pending_ |

## Operational notes

- **Master key rotation:** run `scripts/refresh_bearer_token.sh`, then `podman restart monitoring_prometheus`. Otherwise Scrape Target Down (`litellm`) fires.
- **Adding a model** to `litellm-config.yaml` needs no dashboard change, because panels group by label. If it's a new OpenRouter tier, add it to `router_settings.fallbacks`.
- **Changing the classifier model:** it must exist in `model_list`, or "Smart Router Classifier Failing" fires.
- **LiteLLM upgrade:** run `verify_dashboard.py`. An `unknown metric` result means upstream renamed a metric.
