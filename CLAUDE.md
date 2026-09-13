# localsetup — project context for Claude

Project-specific conventions. Global rules live in `~/.claude/CLAUDE.md`; the full
reference docs are in `docs/` (read at session start) and each stack's README.

## AWS

- **Region: `us-west-2` only.** All AWS resources for this project — including **Amazon SES**
  (email identities, SMTP relay `email-smtp.us-west-2.amazonaws.com:587`) — live in
  `us-west-2`. Do **not** use `us-west-1` for SES; it has no identities (checked 2026-09-12).
- Default CLI profile = account `188627879503` (IAM user `terraform`).
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
  `traefik/`); secrets are per-project `.env` files (git-ignored, `.env.example` alongside).
- Rootless podman: host uid 1000 = uid 0 in containers. A container that must read a
  `chmod 600` bind-mounted secret needs `user: "0"` (see `monitoring/docker-compose.yml`).
- LiteLLM logging policy is **metadata only** — never enable prompt/response logging
  (bank/tax data). See `docs/OBSERVABILITY.md` §3.
- Alerting is Grafana unified alerting only (`monitoring/provisioning/alerting/`); dashboards
  that matter are git-tracked in `monitoring/dashboards/` and checked with
  `scripts/verify_dashboard.py --alerts`.
- Keep `README.md`, this file, the relevant `docs/*.md` and `docs/architecture.drawio` current
  with every change.
