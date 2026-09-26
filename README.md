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
- Grafana (dashboards + alerts): https://grafana.chadrbean.com — `/d/litellm-gateway`, `/d/fail2ban`, `/d/traefik-security`, `/d/kopia`, `/d/hosts`, `/d/ci-overview`, `/d/ci-blog-delivery`

## Off-peak windows (re-verify monthly — DeepSeek changed these Aug 16, 2026)

- Peak (2x) = Mon–Fri **01:00–04:00 UTC** and **06:00–10:00 UTC** (7h/day).
- Everything else + weekends = **half price**.
- Pacific: peak ≈ **6–9pm and 11pm–3am**; off-peak = **9–11pm and 3am–6pm** — the working day is naturally off-peak.

## Documentation

- **Manage stacks with `podman-compose` directly, from inside each project
  directory** (`litellm/`, `monitoring/`, `traefik/`, `serpbear/`, `jenkins/`) — no repo-root wrapper.
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
  the dashboard basic-auth hash; `serpbear/.env` holds the SerpBear login,
  session/API secrets and Google Search Console service account. Each is git-ignored with a matching
  `.env.example` alongside it. This replaced an earlier single root `.env`
  (2026-09-12) — per-project secrets mean podman-compose's own `.env`
  auto-load (from the compose file's directory) just works, no wrapper
  script needed.
- **[.specify/memory/constitution.md](.specify/memory/constitution.md)** — project constitution (v1.0.1, ratified 2026-09-26): nine principles (everything as code, secrets & short-lived credentials, sensitive-data minimisation, catalog-driven gates, contained agents, rootless local-first stacks, verified observability, cost-aware routing, docs current), platform constraints and governance. Every `/speckit-plan` Constitution Check is gated on it.
- **[docs/USAGE.md](docs/USAGE.md)** — how to log in / pass credentials, use LiteLLM (tiers + `smart` router), set up from scratch, daily ops, troubleshooting.
- **[docs/USAGE.md §7](docs/USAGE.md)** — root-causing a failed request: every failure row's `metadata.error_information` in Postgres carries the traceback, and gateway stdout persists to the `litellm_logs` volume (`/var/log/litellm/proxy.log`) since 2026-09-09.
- **[PLAN.md](PLAN.md)** — the implementation plan.
- **[docs/OBSERVABILITY.md](docs/OBSERVABILITY.md)** — LiteLLM metrics, JSON logs, Gateway dashboard, uptime + email alerting: findings, policies, rollout runbook, verification checklist/log.
- **[docs/MODELS.md](docs/MODELS.md)** — model comparison + watchlist (date-stamped pricing).
- **[docs/OFF-PEAK.md](docs/OFF-PEAK.md)** — DeepSeek peak/off-peak windows, caching, batch.
- **[docs/monitoring.drawio](docs/monitoring.drawio)** — architecture diagram: edge (traefik/sshd), fail2ban + nftables, telemetry (exporter/Promtail → Prometheus/Loki → Grafana), LiteLLM gateway observability (blackbox probe, JSON logs), alert email (SES), and the CI/CD band (GitHub App → Traefik → Jenkins → IAM Roles Anywhere → deploy roles; Project board → agent feature pipeline → headless Claude Code → PR).
- **[docs/SECURITY-MONITORING.md](docs/SECURITY-MONITORING.md)** — security monitoring runbook: fail2ban ban policy, exporter + Loki data reference, dashboards, what each alert means + first response, SES alert email, deploy/verify checklist, troubleshooting.
- **[docs/CICD.md](docs/CICD.md)** — Jenkins CI/CD runbook: pipeline map (GitHub Actions → Jenkins), IAM Roles Anywhere bootstrap/renewal/break-glass, per-repo cutover, troubleshooting.
- **[docs/AGENT-PIPELINE.md](docs/AGENT-PIPELINE.md)** — agent feature pipeline: Project board Ready → spec-kit + headless Claude Code in Jenkins → sync main → gate → merged PR → Done. Board/token/image setup, repo onboarding contract, visibility, security model, troubleshooting.
- **[docs/EMAIL-HOSTING.md](docs/EMAIL-HOSTING.md)** — decision record: why no self-hosted mail server (home / ECS / EC2 compared with hosted options on cost, complexity and features). otbla.com uses SES inbound → Lambda → Proton forwarding (live since 2026-09-26), plus a production-access request for replies.
- **[docs/HOSTS.md](docs/HOSTS.md)** — machine inventory (this host + Zuriel's workstation), every file deployed from this repo with its deploy and drift-check command, one-time sudo steps, adding a desktop, Alloy/firewall runbook.
- **[kopia/README.md](kopia/README.md)** — desktop backup agent: tracked policies, S3 repository details, autostart setup, restore-from-scratch commands.

## Edge proxy (traefik/)

`traefik/` runs the public TLS edge for `*.chadrbean.com` (Traefik v3,
Route53 DNS-01 wildcard cert, podman compose, direct on :443).
`caddy/` is the archived predecessor — kept, not running. See
[traefik/README.md](traefik/README.md).

**From this host itself**, `*.chadrbean.com` URLs need `/etc/hosts`
overrides pointing at the LAN IP — the box can't hairpin back through the
router to its own public IP. See "Local access from this host" in
[traefik/README.md](traefik/README.md).

## Rank tracking (serpbear/)

`serpbear/` runs [SerpBear](https://github.com/towfiqi/serpbear) (keyword rank
tracker, pinned image, podman compose) at `https://serpbear.chadrbean.com` via
Traefik → `127.0.0.1:3002`. Its SQLite DB + settings live in the bind mount
`~/.local/share/serpbear/data` so they survive rebuilds; secrets (UI login,
`SECRET`/`APIKEY`, Search Console service account) are in the git-ignored
`serpbear/.env`. DNS is a Route53 A record (`aws-infrastructure` terraform
module `dns`) whose IP is kept current by `scripts/awsChadHomeIp.sh`
(installed at `/usr/local/bin/awsChadHomeIp.sh`, hourly cron). See
[serpbear/README.md](serpbear/README.md).

## CI/CD (jenkins/)

`jenkins/` runs self-hosted **Jenkins LTS** at `https://jenkins.chadrbean.com`, via
Traefik → `127.0.0.1:3010`. It replaced GitHub Actions on 2026-09-24 (GitHub
billing failures). Code stays on GitHub:
- A GitHub App delivers webhooks and receives `jenkins/<pipeline>` commit statuses.
- Each repo keeps its pipelines in `ci/jenkins/*.Jenkinsfile`.
- Jobs are seeded by `jenkins/casc/github/seed.groovy`.
- Shared steps live in `jenkins/shared-library` (`@Library('ci')`). `runCheck` and
  `runCatalogStage` apply a repo's `ci/checks.yml` categories (blocking / advisory /
  monitoring) to check exit codes, so only real defects block a deploy. See `docs/CICD.md`
  § Check catalog & gating.
- blogLosAngeles runs one per-change pipeline, `delivery` (PRs + main: build once →
  checks → terraform → deploy → verify), plus three site-health jobs: `data-health`,
  `security-live` and `seo-live-crawl`. The site-health jobs alert and never block a
  change. Where a change is: the Grafana dashboard **CI — blog delivery**
  (`/d/ci-blog-delivery`), or the `delivery` job page (stage table by pipeline-graph-view).
  Runbook: `docs/CICD.md` "Where is my change?".
- aws-infrastructure, zca-accounting and this repo follow the same model, each with a
  `ci/checks.yml` and a `docs/ci-gates.md` (spec 002):
  - aws-infrastructure `terraform`: checks, then a plan that is always posted to the PR, then
    apply on main. `drift` is a monthly monitoring job that goes red on drift.
  - zca-accounting: every job stays manual-only (its Principle XX). Seed flag `:manual` stops
    pushes from filling history with skipped builds.
- **All projects on one screen:** Grafana **CI — overview (all projects)** (`/d/ci-overview`)
  shows latest results, failing stages, time since last run/success, scheduled staleness,
  pass rate and duration. Alerts: `ci_main_failing`, `ci_monitoring_failing`,
  `ci_scheduled_stale`.
- This repo's own job, `localsetup/ci` (`ci/jenkins/ci.Jenkinsfile`), runs these checks on PRs
  and main (rules: `docs/ci-gates.md`):
  - gitleaks over the full history, honoring `.gitleaksignore` (blocking)
  - trivy config, honoring `.trivyignore.yaml` (advisory)
  - shellcheck (blocking; the vendored spec-kit `.specify/` is excluded)
  - `ci/check_syntax.py`, which you can also run locally: `python3 ci/check_syntax.py` (blocking)

Builds run in containers (`localhost/ci-hugo:1`, `ci-terraform:1`, upstream images)
through the rootless podman socket. AWS access uses **IAM Roles Anywhere**:
- Certs from `scripts/jenkins_ca.sh` are exchanged for 1–2h STS creds.
- No AWS keys are stored.
- The same mechanism replaces the host's static `terraform` IAM user keys.

JCasC config is in `jenkins/casc/`, data in `~/.local/share/jenkins/data`, secrets in
`jenkins/.env` plus `~/.local/share/jenkins/secrets/`. Runbook (pipelines, Roles
Anywhere bootstrap, cutover, troubleshooting): [docs/CICD.md](docs/CICD.md).
Setup: [jenkins/README.md](jenkins/README.md).

### Agent feature pipeline (jenkins/ agent/*)

The pipeline takes a card you drag to **Ready** on the GitHub Project board and, with no
questions, turns it into a gated, merged PR:
- `agent/feature-dispatcher` polls the board every 5 min and claims cards, with a WIP limit
  per repo.
- `agent/feature-worker` runs spec-kit (specify → plan → checklist → tasks → analyze →
  implement) through headless Claude Code (`localhost/ci-claude:1`). It then runs the repo's
  `ci/jenkins/agent-validate.groovy` and gives Claude up to 2 fix passes if that fails.
- Before the gate it merges the latest main in (Claude resolves any conflicts). Then it opens a PR
  and **merges it itself** (squash), so the card lands in **Done** with no review step.
  If the PR's own CI fails, Claude gets the failing log and pushes a fix (up to `fixAttempts`
  times) before the card is Blocked. `autoMerge: false` in config.json brings back In review. PRs touching a repo's
  `manualMergePaths` always wait for you: `terraform/` in aws-infrastructure (a merge applies
  to production), and `jenkins/` + `ci/jenkins/` here. A failure moves the card to
  **Blocked** and sends an issue comment and an email.
- An infrastructure failure (bad Claude token, usage limit, network) instead returns the card to
  Ready and **pauses** the pipeline: the dispatcher health-checks Claude every tick and resumes
  on its own. One email when it pauses, one when it resumes.

Worker runs are named `#<n> blog#226 · <issue title>`, and their description tracks the current
stage.

Progress shows on the card (Stage and Run fields), in one issue comment, in the Jenkins
stage view and in the archived transcripts. The boards it polls (#3 blogLosAngeles, #2 ZCA
Accounting, #4 localsetup, #5 aws-infrastructure), the allowlisted repos and the settings are in
`jenkins/shared-library/resources/agent/config.json`. Onboard a repo with
`scripts/agent_onboard.sh`. Runbook: [docs/AGENT-PIPELINE.md](docs/AGENT-PIPELINE.md).

## SSH brute-force protection (fail2ban/)

`fail2ban/` is a **native** (not containerized — rootless podman can't read
the journal or manage host firewall rules, see its README) fail2ban install
with three jails: `sshd`, `grafana` (Grafana login failures) and `recidive`
(repeat offenders → 1-week all-ports ban). Policy is progressive:
`bantime.increment` doubles each repeat ban up to 4 weeks, ban history kept
30 days, home LAN ignored. A native root `fail2ban_exporter` (`:9191`)
exposes service health and ban/failure gauges to Prometheus. Complements
`traefik/`'s fail2ban HTTP middleware, which can't see SSH traffic (SSH is
not served through Traefik). See
[fail2ban/README.md](fail2ban/README.md).

## Backups (kopia/)

`kopia/` is a **native** (not containerized — it's a desktop GUI app, not a
headless service) KopiaUI install backing up `/home/chad`,
`/home/chad/.local/share/wave`, and `/usr/local/bin` to S3
(`chadrbean-backups`). Tracks the retention/scheduling policies and the
XDG autostart entry (previously missing, so Kopia only ran when launched
by hand) so the whole setup can be recreated from scratch. The ignore file
`kopia/.kopiaignore` (hardlinked to `~/.kopiaignore`) skips caches, build
artifacts and reinstallable tools, and keeps app data, infra secrets and Claude
config. **Zuriel's desktop** (`wkspikaoszuriel`, SSH `zuriel`) runs the same setup
with the same ignore file and policies: `kopia/sync-hosts.sh push|check` keeps them
identical. See [kopia/README.md](kopia/README.md#hosts-keep-both-desktops-identical).
The Hermes watchdog (`hermes/systemd/`, 10-min startup grace) is tracked in
[hermes/README.md](hermes/README.md).

Backup health is monitored from Kopia's own logs on **both desktops** (this
host via Promtail, Zuriel's via Grafana Alloy → Loki → Grafana `/d/kopia`, with a
`$host` picker). Grafana emails if there is **no successful snapshot in 24h** here
or **72h** on Zuriel's (plus a 3h warning here and per-host file/S3/log errors), and
each host's Kopia notification profile emails snapshot failures directly. Runbook:
[docs/KOPIA-MONITORING.md](docs/KOPIA-MONITORING.md).

## Privileged access (automation/)

`chad` and Claude have no standing root. `chad` may only run commands as the unprivileged
`automation` account (`sudo -u automation sudo -n <command>`), which may run a fixed, tiered list
as root: exact-command diagnostics and service control, `host-read` (read-only `grep`/`cat`/`find`
with secrets refused), `host-repo` (symlink-safe cleanup inside `/home/chad/git`), `f2b-unban`, and
`host-deploy` (installs only manifest files from a root-owned clone of merged `main`). Journal and
`/var/log` come through the `adm` group. See [automation/README.md](automation/README.md); the
admin path is `su -`.

## Hosts (docs/HOSTS.md)

This repo is the configuration source for every machine it touches:
[docs/HOSTS.md](docs/HOSTS.md) lists the machines, every file deployed from here
(repo path → host path → deploy command → drift check), and the one-time sudo
steps. Zuriel's workstation reports to this host's Grafana through **Grafana
Alloy** (`monitoring/alloy/`: Kopia logs → Loki, host metrics → Prometheus
remote-write; `deploy.sh stage|push|check`). The **Hosts** dashboard `/d/hosts`
and the **Host disk almost full** alert (>90%, `host-alerts.yml`) cover it. Loki
`:3100` and Prometheus `:9090` accept LAN pushes only from allow-listed hosts
(`monitoring/firewall/`, nftables table `inet monitoring_lan`).

## Status

LIVE: LiteLLM gateway `:4000` in containers (tiers + native `smart` router), postgres on `:5433`,
budgets + spend logging working, Hermes wired through the gateway, off-peak cron guard in place.
Redis response cache: enabled (litellm `cache_params.type: redis`, container
`litellm_redis`, host `127.0.0.1:6380`, key namespace `litellm.response_cache`).

## Observability (monitoring/)

`monitoring/` is a podman compose stack (pod `pod_monitoring`) plus two native
collectors. Full details: [monitoring/README.md](monitoring/README.md). Runbooks:
[docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) (LiteLLM gateway) and
[docs/SECURITY-MONITORING.md](docs/SECURITY-MONITORING.md) (fail2ban, Traefik, Kopia, alert
email, shared deploy). Diagram: [docs/monitoring.drawio](docs/monitoring.drawio).

- **Prometheus** `:9090` (all interfaces, firewalled to loopback + allow-listed LAN
  hosts) — scrapes LiteLLM `:4000/metrics/` (master-key
  bearer from `monitoring/prometheus/bearer_token`, git-ignored; container runs as
  `user: 0:0` so it can read the 0600 file), blackbox probes, Traefik, Loki, Promtail
  and the fail2ban exporter, and receives remote-write from other hosts' Alloy
  (`--web.enable-remote-write-receiver`). 30-day retention.
- **blackbox_exporter** `:9115` — probes LiteLLM `/health/readiness` + `/health/liveliness`
  (no auth), the uptime signal behind **LiteLLM Gateway Down**.
- **Loki** `:3100` (firewalled like Prometheus; Zuriel's Alloy pushes Kopia logs) + native **Promtail** `:9190` — fail2ban log, Traefik access log,
  LiteLLM JSON logs (metadata only — never prompt text; `proxy.log` rotated by a user
  timer), Kopia snapshot/S3/error events (`event`/`source`/`op` labels). 7-day retention;
  attacker-controlled values (IP, Host, path) are structured metadata, not labels.
- **Grafana** `:3000` (loopback) — published as `https://grafana.chadrbean.com`
  through the traefik `grafana` router (fail2ban middleware only — Grafana has its own
  login). Tracked dashboards in `monitoring/dashboards/`: **LiteLLM Gateway** (37 panels),
  fail2ban, Traefik HTTP security, Kopia (per host), Hosts. **All alerting is Grafana-managed** and emails
  through Amazon SES SMTP (us-west-2): LiteLLM gateway down / error rate / provider
  outage / slow responses / key budget / smart-router classifier; fail2ban service down /
  jail missing / log errors / pipeline silent, ban spikes, scrape targets down, Promtail
  drops, TLS cert expiry, Kopia backup freshness and snapshot errors (per host), host disk
  almost full.

Manage via: `podman-compose <args>` from `monitoring/` (e.g. `up -d`, `config`).
Operate via: `podman ps` / `podman pod ps` — podman-compose 1.2.0's `ps` shows nothing
for a running stack. To rotate the scrape bearer, rerun `scripts/refresh_bearer_token.sh`
(reads `LITELLM_MASTER_KEY` from `.env`, rewrites `monitoring/prometheus/bearer_token`
chmod 600) and `podman restart monitoring_prometheus`. Alert email needs SES SMTP
credentials in `monitoring/.env` — see docs/SECURITY-MONITORING.md §7. LiteLLM rollout:
`scripts/rollout_observability.sh`; check every dashboard panel and alert rule with
`./scripts/verify_dashboard.py --alerts`.

Follow-on slices (deferred, not yet wired): node_exporter for workstation metrics,
Hermes dashboard `/api/metrics` (basic-auth), postgres exporter for the litellm db.
See `docs/USAGE.md` for the daily-ops runbook.
