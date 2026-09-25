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
- This repo is CI'd by `localsetup/ci` (`ci/jenkins/ci.Jenkinsfile`). Keep `.sh` files
  shellcheck-clean at warning level and every YAML/JSON parseable (`python3 ci/check_syntax.py`).
  Never commit secrets. `hermes/config.yaml` is a reference copy: its secrets stay blank, and
  the live config is the untracked `~/.hermes/config.yaml`. Add to `.gitleaksignore` only once
  the value is out of the working tree, with a note saying whether it was rotated or accepted.
- Build images are `jenkins/images/ci-*` → `localhost/ci-*:1` (built locally, not pushed).
  ci-hugo's pins must match `blogLosAngeles/.security/tool-versions.env`.
- **Agent feature pipeline** (`agent/feature-dispatcher`, `agent/feature-worker`; runbook
  `docs/AGENT-PIPELINE.md`). Ready cards on the GitHub Project become a spec-kit run in headless
  Claude Code, then a PR, then the card moves to Review. Its Jenkinsfiles live in *this* repo, not
  in the target repos.
  - Config and allowlist: `jenkins/shared-library/resources/agent/config.json`. A repo not listed
    there is never checked out.
  - Per-repo gate: `ci/jenkins/agent-validate.groovy`, loaded from the target repo's **main**,
    never from the agent's branch. Wrap each command in `agentCheck()`.
  - Claude runs only inside `localhost/ci-claude*` with `IS_SANDBOX=1` + bypassPermissions, and
    gets no GitHub, AWS or podman access. Push, PR and board updates stay in the pipeline. Keep
    it that way.
  - Agent commits are authored by `jenkins-agent@chadrbean.com`. Never use `jenkins-bot`:
    `skipIfBotCommit` would then skip the target repo's own PR checks.
  - Board access needs the classic PAT credential `agent-gh-project-pat`. The GitHub App can't
    write user-owned Projects v2.
