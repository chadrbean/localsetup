# localsetup — project context for Claude

Project-specific conventions. Global rules live in `~/.claude/CLAUDE.md`; the full
reference docs are in `docs/` (read at session start) and each stack's README.

## AWS

- **Region: `us-west-2` only.** All AWS resources for this project — including **Amazon SES**
  (email identities, SMTP relay `email-smtp.us-west-2.amazonaws.com:587`) — live in
  `us-west-2`. Do **not** use `us-west-1` for SES; it has no identities (checked 2026-09-12).
- Default CLI profile = account `188627879503`. As of 2026-09-24 it's still IAM user `terraform`
  (static keys), which is being replaced by the **IAM Roles Anywhere** role `host-admin-terraform`
  (`credential_process` + cert CN `chad-host-terraform`). See `docs/CICD.md` § AWS auth. Don't
  add new static access keys anywhere; CI and host both use Roles Anywhere certs from
  `scripts/jenkins_ca.sh`.
- SES identities (us-west-2): domain `chadrbean.com` (verified, DKIM) and recipient
  `crb4u@yahoo.com` (verified). Account is in the SES sandbox (verified recipients only).
- Grafana alert email reuses the **Terraform-managed** IAM user `hermes-ses-email`
  (`~/git/aws-infrastructure`, outputs `hermes_ses_email_access_key_id` /
  `hermes_ses_email_smtp_password`); the sender must be `hermes@chadrbean.com`. **Don't create
  IAM users out-of-band.** Creds live in the git-ignored `monitoring/.env` (`GRAFANA_SMTP_*`,
  `ALERT_EMAIL_TO`). See `docs/SECURITY-MONITORING.md` §7.
- Runbooks: `docs/SECURITY-MONITORING.md` (fail2ban, Traefik, Kopia, alert email, shared deploy)
  and `docs/OBSERVABILITY.md` (LiteLLM gateway metrics/logs/dashboard/alerts, rollout script).

## Stacks & conventions

- Manage stacks with `podman-compose` from inside each directory (`litellm/`, `monitoring/`,
  `traefik/`, `serpbear/`, `homepage/`, `jenkins/`); secrets are per-project `.env` files (git-ignored, `.env.example` alongside).
- Persistent app data is **bind-mounted from `~/.local/share/<app>/`** (not named volumes) so it
  survives rebuilds — `serpbear/` uses `~/.local/share/serpbear/{data,secrets}`.
- New `*.chadrbean.com` app checklist: `traefik/dynamic.yml` router+service, `/etc/hosts` hairpin,
  `aws-infrastructure` `modules/dns` A record, and the hostname in `DNS_RECORDS` of
  `scripts/awsChadHomeIp.sh` (tracked copy; install to `/usr/local/bin/`, hourly cron). SerpBear
  = port `127.0.0.1:3002`.
- Rootless podman: host uid 1000 = uid 0 in containers. A container that must read a
  `chmod 600` bind-mounted secret needs `user: "0"` (see `monitoring/docker-compose.yml`).
- LiteLLM logging policy is **metadata only** — never enable prompt/response logging
  (bank/tax data). See `docs/OBSERVABILITY.md` §3.
- Alerting is Grafana unified alerting only (`monitoring/provisioning/alerting/`); dashboards
  that matter are git-tracked in `monitoring/dashboards/` and checked with
  `scripts/verify_dashboard.py --alerts`.
- Keep `README.md`, this file, the relevant `docs/*.md` and `docs/monitoring.drawio` (the
  architecture diagram) current with every change.

## CI/CD (Jenkins, replaced GitHub Actions 2026-09-24)

- `jenkins/` = Jenkins LTS at `jenkins.chadrbean.com` → `127.0.0.1:3010`. It's configured only
  through JCasC (`jenkins/casc/`); UI edits are lost on restart. Runbook: `docs/CICD.md`.
  An unknown JCasC key makes Jenkins boot-loop (`UnknownAttributesException`), so only use keys
  in the error's "Available attributes" list or `/configuration-as-code/reference`. For example,
  pipeline-graph-view has none. Also, `podman-compose up -d --build` doesn't recreate a running
  container: add `--force-recreate`.
- Pipelines live in each app repo as `ci/jenkins/<name>.Jenkinsfile`, and a job exists only
  if it's listed in `jenkins/casc/github/seed.groovy`. Use the shared library
  (`jenkins/shared-library/vars`) instead of re-implementing AWS auth, PR comments, bot pushes
  or path filters.
- AWS in pipelines: `withAwsRole('<key>')` only. A new key needs:
  1. an entry in `shared-library/resources/aws-roles.json`
  2. a cert from `scripts/jenkins_ca.sh issue <cn> --jenkins`
  3. a Roles Anywhere trust statement on the role (CN condition)
  4. the role in the aws-infrastructure `ci_jenkins_role_names` (profile) list
- Container steps use `agent { docker { image '…'; args '-u 0:0' } }` so workspace files stay
  owned by host uid 1000. `JENKINS_HOME` must stay mounted at the same absolute path.
- Run reports: emit JUnit / Cobertura / SARIF (checkov, trivy, gitleaks) / eslint checkstyle
  and call `publishReports(...)` in `post { always }`. Don't call `junit`/`recordIssues`/
  `publishHTML` directly. See `docs/CICD.md` § Run reports.
- Seed flags: `name:main` discovers only main. `name:manual` never builds on push, PR or
  indexing, so no NOT_BUILT noise, while manual, `build job:` and cron still run. All
  zca-accounting jobs (Principle XX), `aws-infrastructure/drift` and the blog site-health jobs are
  `:manual`. Use the shared `manualOnly()` allow-list guard instead of hand-rolled cause checks.
  Only use Job DSL strategy/filter names that have an `@Symbol`: a wrong name fails the seed at
  boot (the named-branch exact filter has none). See `specs/002-all-project-pipelines/`.
- Gating: a repo with `ci/checks.yml` (blogLosAngeles, aws-infrastructure, zca-accounting,
  localsetup) runs every check through
  `runCheck(id:)` / `runCatalogStage(stage:)`. The catalog `category` (blocking / advisory /
  monitoring) decides fail vs warn, using exit codes 0 pass, 1 findings, 2 error,
  3 inconclusive, 4 n/a. Never make a production-data or live-site check blocking: those are
  `monitoring` and belong in a site-health job. runCheck records failures without throwing, so
  a later stage that must not run after a failure needs
  `when { expression { currentBuild.currentResult != 'FAILURE' } }`. Put `checkReport()`
  before `stepSummary()` in `post { always }`. Accepted findings go in the tool's ignore file
  (`.trivyignore.yaml` with paths and a statement). Never use `publishReports(failOnNewIssues:)`
  in a catalog repo: it is sticky and overrides the catalog. See `docs/CICD.md` § Check
  catalog & gating, `specs/001-blog-pipeline-visibility/` and `specs/002-all-project-pipelines/`.
- Cross-project CI view: Grafana `monitoring/dashboards/ci-overview.json`, with alerts
  `ci_main_failing`, `ci_monitoring_failing` and `ci_scheduled_stale` in `ci-alerts.yml`. Grafana
  threshold evaluators have **no `eq`**: use `within_range [1.5, 2.5]` for "== 2". An `eq` rule
  sits in error state and never fires. Always run `verify_dashboard.py --alerts` after changing
  rules.
- blogLosAngeles = one `delivery` job (stage names are a contract: `Prepare`, `Maintain
  content`, `Build`, `Checks`/`tests|security|seo`, `Infrastructure`, `Deploy`, `Verify`).
  The Grafana dashboard `monitoring/dashboards/ci-blog-delivery.json` and the catalog depend
  on these names, so rename them together. Site-health jobs are `:main:manual`.
- This repo is CI'd by `localsetup/ci` (`ci/jenkins/ci.Jenkinsfile`). Keep `.sh` files
  shellcheck-clean at warning level and every YAML/JSON parseable (`python3 ci/check_syntax.py`).
  Never commit secrets. `hermes/config.yaml` is a reference copy: its secrets stay blank, and
  the live config is the untracked `~/.hermes/config.yaml`. Add to `.gitleaksignore` only once
  the value is out of the working tree, with a note saying whether it was rotated or accepted.
- Build images are `jenkins/images/ci-*` → `localhost/ci-*:1` (built locally, not pushed).
  ci-hugo's pins must match `blogLosAngeles/.security/tool-versions.env`.
