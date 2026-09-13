# localsetup

Local AI routing setup — a self-hosted, OpenAI-compatible gateway (LiteLLM)
that routes every task to the cheapest model good enough for it.

## Goal

Most value per dollar:

- **DeepSeek V4-Flash** — implementation + automated repetitive tasks (the cost floor, ~$0.14/$0.28 per M, cache-hit $0.0028).
- **DeepSeek V4-Pro** — planning + medium coding + reasoning.
- **Kimi K2.6** — "reasonable high-end" escalator for hard coding / long docs / agentic work.

Plus automatic complexity routing (LiteLLM Auto Router v2, model `smart`), per-consumer budgets (LiteLLM), and stacked
discounts: **off-peak scheduling**, **prompt caching**, and **batch APIs**.

## Stack

- **LiteLLM proxy** `:4000/v1` — explicit tiers (`flash` / `pro` / `kimi`) + OpenRouter **lite** tier (`or-lite-glm` / `or-lite-qwen` — cheap, everyday) + OpenRouter **planning** tier (`or-plan-qwen` / `or-plan-minimax` — deep context, frontier reasoning) + `gpt5` / `kimi-code` + native **Auto Router v2** (model `smart`), budgets, fallbacks, spend logs, and guardrails (`hide-secrets`, prompt-injection heuristics). http://localhost:4000/ui
- **Provider principle: direct connection first, OpenRouter for the long tail.** Go direct whenever the economics justify it, and fall back to OpenRouter otherwise. Direct buys things an aggregator structurally cannot: DeepSeek native is the only way to get cache-hit ($0.0028/M) and off-peak pricing, and going direct sidesteps OpenRouter's account-level guardrail/data-policy layer — which is where *every* routing failure on 2026-09-07 originated (Z.AI flapping, free endpoints blocked). Use OpenRouter when a model isn't worth its own account, or when no direct option exists.
- Docker Compose (podman-compatible) + Postgres for keys/spend. Hermes wiring mirrored in `hermes/config.yaml` for reference (the live copy is `~/.hermes/config.yaml`).
- **Auto Router ladder (retuned 2026-09-08/09):** SIMPLE → `or-lite-glm`, MEDIUM → `or-lite-deepseek-flash` ("routine engineering" workhorse), COMPLEX → `or-plan-minimax`, REASONING → `or-plan-qwen` ("very complex" only). Driven by the LLM classifier on the **`agentic` rubric** — see [docs/USAGE.md §4](docs/USAGE.md) for why that one line matters and how to tell when the classifier is silently failing.
- **Note on OpenRouter workspace Guardrails** (openrouter.ai/workspaces/default/guardrails): Qwen and MiniMax needed explicit allow-listing (done 2026-09-05). **Z.AI intermittently returns `0 endpoints out of 17 ... Provider not allowed by guardrail` even while allowed** — observed on 2026-09-07 passing 3/3 and failing minutes later, and again 2026-09-09 when trialed as classifier (404 with strict json_schema). That flap took out the router's classifier and silently degraded all routing to flash, so the classifier was moved to `or-lite-qwen`, then to `or-lite-deepseek-flash` (2026-09-09) after qwen3.7-flash's shared pool rate-limited repeatedly. A two-deployment classifier group does **not** fix this: OpenRouter returns 404 for a guardrail block and LiteLLM's `RetryPolicy` has no `NotFoundErrorRetries`, so it never fails over. Keep request-critical paths off flappy providers.

## Reference URLs

- Admin UI (log in with `LITELLM_MASTER_KEY`): http://localhost:4000/ui
- LiteLLM API — all model calls incl. `smart` router (Bearer key): http://localhost:4000/v1
- RouteLLM auto-router (RETIRED — replaced by LiteLLM native `smart`; was :6060)

## Off-peak windows (re-verify monthly — DeepSeek changed these Aug 16, 2026)

- Peak (2x) = Mon–Fri **01:00–04:00 UTC** and **06:00–10:00 UTC** (7h/day).
- Everything else + weekends = **half price**.
- Pacific: peak ≈ **6–9pm and 11pm–3am**; off-peak = **9–11pm and 3am–6pm** — the working day is naturally off-peak.

## Documentation

- **Manage stacks with `podman-compose` directly, from inside each project
  directory** (`litellm/`, `monitoring/`, `traefik/`) — no repo-root wrapper.
  Each project has its own `.env` (git-ignored; copy `.env.example` and fill
  it in) sitting next to its compose file, which podman-compose auto-loads
  for `${VAR}` substitution — see "Secrets" below.
  `litellm/` and `monitoring/` use `docker-compose.yml`; `traefik/` uses
  `docker-compose.yaml`, so pass `-f docker-compose.yaml` there. e.g.
  `cd litellm && podman-compose up -d`. Note: podman-compose 1.2.0's `ps`
  shows nothing for a running stack; use `podman ps` / `podman pod ps` for
  status.
- **Secrets live per-project, not in a repo-root `.env`.** `litellm/.env`
  holds provider keys + virtual keys + Redis/DB passwords; `monitoring/.env`
  holds Grafana admin credentials; `traefik/.env` holds AWS DNS-01 keys +
  the dashboard basic-auth hash. Each is git-ignored with a matching
  `.env.example` alongside it. This replaced an earlier single root `.env`
  (2026-09-12) — per-project secrets mean podman-compose's own `.env`
  auto-load (from the compose file's directory) just works, no wrapper
  script needed.
- **[docs/USAGE.md](docs/USAGE.md)** — how to log in / pass credentials, use LiteLLM (tiers + `smart` router), set up from scratch, daily ops, troubleshooting.
- **[docs/USAGE.md §7](docs/USAGE.md)** — root-causing a failed request: every failure row's `metadata.error_information` in Postgres carries the traceback, and gateway stdout persists to the `litellm_logs` volume (`/var/log/litellm/proxy.log`) since 2026-09-09.
- **[PLAN.md](PLAN.md)** — the implementation plan.
- **[docs/OBSERVABILITY.md](docs/OBSERVABILITY.md)** — LiteLLM metrics, JSON logs, Gateway dashboard, uptime + email alerting: findings, policies, rollout runbook, verification checklist/log.
- **[docs/MODELS.md](docs/MODELS.md)** — model comparison + watchlist (date-stamped pricing).
- **[docs/OFF-PEAK.md](docs/OFF-PEAK.md)** — DeepSeek peak/off-peak windows, caching, batch.
- **[kopia/README.md](kopia/README.md)** — desktop backup agent: tracked policies, S3 repository details, autostart setup, restore-from-scratch commands.

## Edge proxy (traefik/)

`traefik/` runs the public TLS edge for `*.chadrbean.com` (Traefik v3,
Route53 DNS-01 wildcard cert, podman compose, sslh :443 → :18443).
`caddy/` is the archived predecessor — kept, not running. See
[traefik/README.md](traefik/README.md).

**From this host itself**, `*.chadrbean.com` URLs need `/etc/hosts`
overrides pointing at the LAN IP — the box can't hairpin back through the
router to its own public IP. See "Local access from this host" in
[traefik/README.md](traefik/README.md).

## SSH brute-force protection (fail2ban/)

`fail2ban/` is a **native** (not containerized — rootless podman can't read
the journal or manage host firewall rules, see its README) fail2ban install
protecting sshd. Complements `traefik/`'s fail2ban HTTP middleware, which
can't see SSH traffic (sslh forwards it straight to sshd, bypassing
Traefik). See [fail2ban/README.md](fail2ban/README.md).

## Backups (kopia/)

`kopia/` is a **native** (not containerized — it's a desktop GUI app, not a
headless service) KopiaUI install backing up `/home/chad`,
`/home/chad/.local/share/wave`, and `/usr/local/bin` to S3
(`chadrbean-backups`). Tracks the retention/scheduling policies and the
XDG autostart entry (previously missing, so Kopia only ran when launched
by hand) so the whole setup can be recreated from scratch. See
[kopia/README.md](kopia/README.md).

## Status

LIVE: LiteLLM gateway `:4000` in containers (tiers + native `smart` router), postgres on `:5433`,
budgets + spend logging working, Hermes wired through the gateway, off-peak cron guard in place.
Redis response cache: enabled (litellm `cache_params.type: redis`, container
`litellm_redis`, host `127.0.0.1:6380`, key namespace `litellm.response_cache`).

## Observability (monitoring/)

`monitoring/` is a podman compose stack (pod `pod_monitoring`) — see
[monitoring/README.md](monitoring/README.md) for the full reference and
[docs/architecture.drawio](docs/architecture.drawio) for the diagram. At a glance:

- **Prometheus** `:9090` — scrapes LiteLLM `/metrics/`, blackbox probes, Traefik, Loki,
  Promtail and itself. 30d retention.
- **blackbox_exporter** `:9115` — probes LiteLLM `/health/readiness` + `/health/liveliness`
  (the uptime signal; no auth needed).
- **Grafana** `:3000` — published as `https://grafana.chadrbean.com` (traefik fail2ban
  middleware only — Grafana has its own login). Dashboards: **LiteLLM Gateway**
  (version-controlled `monitoring/dashboards/litellm-gateway.json`, 37 panels), fail2ban, Kopia.
- **Loki** `:3100` — log store, 7d retention: fail2ban, Traefik access, LiteLLM (JSON,
  metadata only — no prompt text) and Kopia logs.
- **Promtail** `:9190` — native systemd user service shipping those logs, plus
  `promtail_custom_litellm_*` log-derived counters.

**Alerting** is Grafana unified alerting only (`monitoring/provisioning/alerting/`),
emailed through Amazon SES SMTP: LiteLLM Gateway Down, Metrics Scrape Failing, High Error
Rate, Provider Outage, Slow Responses, Key Budget Low, Smart Router Classifier Failing,
Promtail/Loki health, fail2ban and Kopia rules.

Verify the dashboard and rules end to end with `./scripts/verify_dashboard.py --alerts`.

