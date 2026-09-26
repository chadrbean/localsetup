# Backup coverage (Kopia)

Kopia backs up three sources on this host (`wkspikaoschad`): `/home/chad`, `/home/chad/.local/share/wave`
and `/usr/local/bin` ([kopia/README.md](../kopia/README.md)). Rules in [kopia/.kopiaignore](../kopia/.kopiaignore)
use gitignore semantics: the last matching rule wins, and an excluded directory is never entered, so a nested
`.kopiaignore` inside it is never read. Kopia does not read `.gitignore`. Audited 2026-09-26; `kopia/` was not changed.
**Backed up**: **yes** = in a source and nothing excludes it or its contents (at-any-depth build-artifact rules
such as `node_modules/` aside); **partly** = entered but named children excluded, or only named children
re-included; **no** = excluded by a rule or outside every source.
Update this document when a stack or app data directory is added, a compose mount or named volume changes,
or `kopia/.kopiaignore` changes.

## Coverage

Named volumes are rootless podman's, under `~/.local/share/containers/storage/volumes/` (written `…/volumes/` below).

| Service | Path | Holds | Backed up | Note |
|---|---|---|---|---|
| localsetup (checkout) | `~/git/localsetup` | all stack config, git-ignored `.env` files, runtime files | yes | no rule excludes `/git/`; also on the GitHub remote. Git-ignored `*/.env`, `traefik/logs/`, `monitoring/data/dashboards/`, `monitoring/prometheus/bearer_token`, `gsc-mcp/client_secrets.json`, `caddy/.env` are backed up too |
| litellm | `~/git/localsetup/litellm/` (`litellm-config.yaml`, `.env`) | config, secrets | yes | checkout |
| litellm | `…/volumes/litellm_postgres_data` | virtual keys, budgets, spend | no | `/.local/share/*`, no `!` re-include |
| litellm | `…/volumes/litellm_redis_data`, `…/volumes/litellm_logs` | cache; proxy log | no | `/.local/share/*` |
| monitoring | `~/git/localsetup/monitoring/` (`provisioning/`, `dashboards/`, `dashboards-otbla/`, `data/dashboards/`, `prometheus/bearer_token`, config files, `.env`) | config, dashboards, secrets | yes | checkout; the `${GOOGLE_SA_KEY_PATH}` mount cannot be determined from the repo (see below) |
| monitoring | `…/volumes/monitoring_grafana_data` | Grafana DB: users, API tokens, UI state | no | `/.local/share/*` |
| monitoring | `…/volumes/monitoring_prometheus_data`, `…/volumes/monitoring_loki_data` | metrics and log history | no | `/.local/share/*` |
| monitoring | `~/.config/systemd/user/` (promtail, litellm-logrotate units) | host agent units | yes | no rule |
| monitoring | `~/.local/bin/promtail` | reinstallable binary | no | `/.local/*` |
| monitoring | `/etc/nftables.d/`, `/etc/systemd/system/` (LAN firewall) | firewall drop-ins | no | not in a backup source; git is the copy |
| traefik | `~/git/localsetup/traefik/` (`traefik.yml`, `dynamic.yml`, `.env`, `logs/`) | config, secrets, access logs | yes | checkout |
| traefik | `…/volumes/traefik_data` (`acme.json`) | ACME account and certs | no | `/.local/share/*` |
| serpbear | `~/.local/share/serpbear/` (`data/`, `secrets/`) | app DB, secrets | yes | `!/.local/share/serpbear/` |
| homepage | `~/.local/share/homepage/config` | dashboard config | yes | `!/.local/share/homepage/` |
| jenkins | `~/.local/share/jenkins/` | CI home, CA, secrets | partly | `!/.local/share/jenkins/` then `/.local/share/jenkins/*`; only `ca/` and `secrets/` re-included |
| jenkins | `~/.local/share/jenkins/ca/`, `~/.local/share/jenkins/secrets/` | Roles Anywhere CA; GitHub App key, CI certs | yes | `!/.local/share/jenkins/ca/`, `!/.local/share/jenkins/secrets/` |
| jenkins | `~/.local/share/jenkins/data/` | JENKINS_HOME: build history, job state, `paused.json`, own `secrets/master.key` | no | `/.local/share/jenkins/*` |
| jenkins | `~/git/localsetup/jenkins/` (`casc/`, `.env`) | JCasC config, secrets | yes | checkout; `casc/` also in git |
| jenkins | `~/.local/share/aws-roles-anywhere/` | host Roles Anywhere cert/key (`scripts/jenkins_ca.sh --host`) | yes | `!/.local/share/aws-roles-anywhere/` |
| hermes | `~/.hermes/` | agent state, `config.yaml`, DBs, sessions | partly | install, caches, logs and backups excluded by the `/.hermes/…` rules (`hermes-agent/`, `tools/`, `bin/`, `cache/`, `lsp/`, `installs/`, `audio_cache/`, `image_cache/`, `logs/`, `*.bak*`) |
| hermes | `~/.config/systemd/user/` (watchdog script + unit) | watchdog | yes | no rule |
| decap | `~/.config/systemd/user/decap-server.service` | unit | yes | no rule |
| decap | `~/.npm-global/bin/decap-server` | reinstallable binary | no | `/.npm-global/` |
| decap | `~/git/blogLosAngeles` | blog working copy it writes | yes | no rule excludes `/git/`; also on its remote |
| gsc-mcp | `~/git/localsetup/gsc-mcp/` (`.env`, `client_secrets.json`) | OAuth client secrets | yes | checkout |
| caddy | `~/git/localsetup/caddy/.env` | archived stack, still holds credentials | yes | checkout |
| fail2ban | `/etc/fail2ban/`, `/etc/systemd/system/` (exporter unit) | jails, filters, unit | no | not in a backup source; git is the copy |
| fail2ban | `/usr/local/bin/` (exporter) | exporter | yes | source `/usr/local/bin` |
| sshd | `/etc/ssh/sshd_config.d/10-key-only.conf` | sshd drop-in | no | not in a backup source; git is the copy |
| sysctl | `/etc/sysctl.d/99-unpriv-443.conf` | unprivileged `:443` for Traefik | no | not in a backup source; git is the copy |
| automation | `/etc/sudoers.d/`, `/etc/host-deploy/`, `/usr/local/sbin/` | sudoers, deploy manifest, root helpers | no | not in a backup source; git is the copy |
| automation | `/usr/local/bin/awsChadHomeIp.sh` (`scripts/`) | DNS updater | yes | source `/usr/local/bin`; its `/etc/crontab` line is not |
| kopia | `~/.kopiaignore` | hardlink of `kopia/.kopiaignore` | yes | no rule |
| kopia | `~/.config/kopia/repository.config` | repository connection | yes | no rule; useless without the repository password |
| kopia | `~/.config/autostart/kopia-ui.desktop` | KopiaUI autostart | yes | no rule |

`jenkins/README.md` says a nested `~/.local/share/jenkins/data/.kopiaignore` skips workspaces. It is never
read, because `data/` is excluded and never entered. The README is not edited here (see #38).

## Deliberately not backed up

- **Jenkins `data/`** (build history, job state, ~48 GB): a rebuild needs only JCasC (git), `jenkins/.env`
  (checkout) and the kept `secrets/` + `ca/`. Jenkins' own `data/secrets/master.key` is not kept, so
  credentials come from JCasC and the mounted `secrets/` directory, not from a restored `credentials.xml`.
- **Caches**: `litellm_redis_data`, `~/.cache/`, the Hermes caches.
- **Logs and metrics history**: `litellm_logs`, `monitoring_prometheus_data`, `monitoring_loki_data`.
- **Reinstallable installs and toolchains**: `~/.local/bin/promtail`, `~/.npm-global/`, the Hermes install.
- **`/etc` drop-ins**: outside every source by design; the repo is their copy (`docs/HOSTS.md` redeploys them).

## Gaps

- **`…/volumes/litellm_postgres_data`** — LiteLLM virtual keys, budgets and spend history — `/.local/share/*`
- **`…/volumes/monitoring_grafana_data`** — Grafana DB: users, API tokens, UI-only state — `/.local/share/*`
- **`…/volumes/traefik_data`** (`acme.json`) — ACME account and certificates (re-issuable, but rate-limited) — `/.local/share/*`

Fixing these (a `!` re-include, or a dump into a backed-up directory) is #38; this audit changes no rules.

## Restore order

1. **Out-of-band first**: the Kopia repository password and the S3 credentials come from the password
   manager; no backup holds them. Connect the repository.
2. Restore `~/git/localsetup` (every stack's `.env`) and `~/.local/share/aws-roles-anywhere/`.
3. **Traefik** (edge): config and `.env` from the checkout; `acme.json` is re-issued on start.
4. **Jenkins**: `~/.local/share/jenkins/ca/` and `secrets/`, JCasC from git; build history starts empty.
5. **Monitoring**: config, dashboards and `.env` from the checkout; Grafana DB state is recreated by hand.
6. **LiteLLM**: config and `.env` from the checkout; Postgres keys and budgets are recreated by hand.
7. serpbear and homepage (`~/.local/share/<app>/`), hermes (`~/.hermes/`), decap (unit + `~/git/blogLosAngeles`).

Commands: [kopia/README.md](../kopia/README.md) ("Restore from scratch").

## Not determinable from the repo

- Zuriel's host (`wkspikaoszuriel`) shares these rules, but which of these paths exist there, and its sources,
  cannot be determined from the repo.
- `${GOOGLE_SA_KEY_PATH}`: its location is only in the untracked `monitoring/.env`.
