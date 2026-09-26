# Research: Backup coverage audit (003)

All findings come from files in this repo (paths relative to the repo root). Line numbers
refer to `kopia/.kopiaignore` at the commit this plan was written on; the document quotes
the rule text, not the number, so it stays valid if lines move.

## R1. What Kopia backs up (sources)

- **Decision**: Three sources on this host: `/home/chad` (hourly, gzip —
  `kopia/policies/home-chad.json`), `/home/chad/.local/share/wave` and `/usr/local/bin`
  (global policy). Source: `kopia/README.md` "What's running", `README.md` § Backups.
- **Rationale**: That is what the repo states; `/etc`, `/var` and podman's system dirs are
  outside every source, so they get "not in a backup source", not an ignore line.
- **Consequence**: `/usr/local/bin` IS covered, so the installed `awsChadHomeIp.sh` and the
  fail2ban exporter binary/script there are backed up (as well as being in git).
- **Alternatives**: treating `/home/chad` as the only source (the spec's first assumption) —
  rejected, the README lists three.

## R2. How rules are applied

- **Decision**: gitignore semantics as documented in the file header (lines 7–13): anchored
  `/x/`, unanchored `x/` at any depth, last matching rule wins, and an excluded directory is
  never entered. `global.json` adds `.kopiaignore` as the ignore-file name, so a nested
  `.kopiaignore` only matters inside a directory Kopia actually enters.
- **Rationale**: FR-005; the header is the project's own statement of the semantics.

## R3. Where the stacks' data lives

| Stack | Host locations (source file) |
|---|---|
| litellm | `./litellm-config.yaml`, `./.env` (bind); named volumes `litellm_postgres_data`, `litellm_redis_data`, `litellm_logs` (`litellm/docker-compose.yml`) |
| monitoring | `./provisioning`, `./dashboards`, `./dashboards-otbla`, `./data/dashboards`, `./prometheus/bearer_token`, config files (bind); `${GOOGLE_SA_KEY_PATH}` (path only in `.env`); named volumes `monitoring_prometheus_data`, `monitoring_grafana_data`, `monitoring_loki_data` |
| traefik | `./traefik.yml`, `./dynamic.yml`, `./logs`, `./.env`; named volume `traefik_data` holding `/data/acme.json` (`traefik.yml` `acme.storage`) |
| serpbear | `~/.local/share/serpbear/data` (bind; `secrets` per CLAUDE.md) |
| homepage | `~/.local/share/homepage/config` (bind) |
| jenkins | `~/.local/share/jenkins/{data,secrets,ca}` (bind; `jenkins/README.md` table), `./casc` (git), `./.env` |
| hermes | `~/.hermes/` (live install + `config.yaml`), watchdog in `~/.config/systemd/user/` (`hermes/README.md`) |
| decap | unit in `~/.config/systemd/user/`; binary `~/.npm-global/bin/decap-server`; writes `~/git/blogLosAngeles` (`decap/decap-server.service`) |
| gsc-mcp | `gsc-mcp/.env` and `gsc-mcp/client_secrets.json` in the checkout (`gsc-mcp/.env.example`) |
| caddy | archived; `caddy/.env` still holds route53 keys (`caddy/README.md`) |
| fail2ban, sshd, sysctl, automation | `/etc/...` drop-ins, `/usr/local/bin`, `/usr/local/sbin`, `/etc/host-deploy/` (`docs/HOSTS.md` deployed-files table) |
| kopia | `~/.kopiaignore` (hardlink), `~/.config/kopia/repository.config`, `~/.config/autostart/` |
| monitoring (host agents) | promtail + logrotate units in `~/.config/systemd/user/`; `~/.local/bin/promtail` |
| monitoring (LAN firewall) | `/etc/nftables.d/`, `/etc/systemd/system/` (`docs/HOSTS.md`; found at implement-time re-check T002) |

## R4. Where named volumes live

- **Decision**: Rootless podman named volumes are under
  `~/.local/share/containers/storage/volumes/<name>/_data`. The repo states this explicitly
  for `litellm_logs` (`monitoring/promtail/promtail-config.yaml`, `docs/USAGE.md`,
  `scripts/rollout_observability.sh`); all stacks run under the same rootless podman, so the
  same root applies to every named volume.
- **Verdict**: **no** for all of them — `/.local/share/*` excludes `containers/`, and no
  `!` rule re-includes it.
- **Alternatives**: "cannot be determined" (the spec's edge case) — rejected, because the
  repo does show the storage root.

## R5. Where the repo checkout lives, and git-ignored files in it

- **Decision**: The checkout is `~/git/localsetup` (`gsc-mcp/.env.example`
  `GOOGLE_CLIENT_SECRETS_FILE`, `automation/README.md` `/home/chad/git`). No rule excludes
  `/git/` (only `node_modules/`, `.venv/`, `venv/`, `__pycache__/`, `.terraform/`, worktrees).
- **Consequence**: Every git-ignored secret and runtime file inside stack dirs —
  `*/.env`, `traefik/logs/`, `monitoring/data/dashboards/`, `monitoring/prometheus/bearer_token`,
  `gsc-mcp/client_secrets.json`, `caddy/.env` — **is backed up** by Kopia (Kopia does not
  read `.gitignore`). This is the main restore path for stack secrets.

## R6. Jenkins

- **Decision**: `~/.local/share/jenkins` = **partly**: `ca/` and `secrets/` yes; `data/`
  (JENKINS_HOME: build history, job state, `agent-pipeline/paused.json`, Jenkins' own
  `secrets/master.key`) no, via `/.local/share/jenkins/*`. Configuration is JCasC in git and
  credentials come from `jenkins/.env` (in the checkout, backed up) and the mounted
  `secrets/` dir, so a rebuild needs nothing from `data/`.
- **Discrepancy found**: `jenkins/README.md` says Kopia covers `~/.local/share/jenkins` and a
  nested `data/.kopiaignore` skips workspaces. Under R2 that nested file is never read,
  because `data/` is excluded. The document states this; the README is **not** edited here,
  because `jenkins/` is in the agent pipeline's `manualMergePaths` and the fix belongs with
  #38.

## R7. "Worth keeping" classification

- **Decision**: Gaps = secrets, app databases and non-regenerable state:
  `litellm_postgres_data` (virtual keys, budgets, spend), `monitoring_grafana_data`
  (Grafana DB: users, API tokens, UI-only state), `traefik_data` (`acme.json`: ACME account
  and certs; re-issuable but rate-limited). Not gaps (deliberate or regenerable):
  `litellm_redis_data` (cache), `litellm_logs`, `traefik/logs` is backed up anyway,
  `monitoring_prometheus_data` / `monitoring_loki_data` (metrics/log history), Jenkins
  `data/`, caches/toolchains.
- **Rationale**: matches the ignore file's own section comments ("caches", "build history",
  "state, not the reinstallable install").

## R8. Restore order

- **Decision**: 0) out-of-band: Kopia repository password + S3 credentials (password
  manager; `kopia/README.md` "Restore from scratch"); 1) Kopia repo connection + `~/git/localsetup` (secrets `.env` files) and
  `~/.local/share/aws-roles-anywhere/`; 2) Traefik (edge); 3) Jenkins
  (`~/.local/share/jenkins/{ca,secrets}` + JCasC); 4) monitoring; 5) LiteLLM (DB is not
  restorable — keys re-created); 6) serpbear, homepage, hermes, decap. Commands: link to
  `kopia/README.md`.

## R9. Zuriel's host

- **Decision**: Only the shared rules are known; which of these paths exist there, and its
  sources, cannot be determined from the repo. One sentence, no rows.

## Implement-time re-check (T001/T002, 2026-09-26)

R1–R2 hold unchanged. R3 holds; one addition: the monitoring LAN firewall drop-ins
(`/etc/nftables.d/`, `/etc/systemd/system/`), outside every source. `~/.local/share/aws-roles-anywhere/`
is issued by `scripts/jenkins_ca.sh issue <cn> --host`, so the doc lists it under `jenkins`.
