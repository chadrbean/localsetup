---

description: "Task list for 003 backup coverage audit (docs/BACKUP-COVERAGE.md)"
---

# Tasks: Backup coverage audit (docs/BACKUP-COVERAGE.md)

**Input**: Design documents from `specs/003-backup-coverage-doc/`

**Prerequisites**: plan.md, spec.md, research.md (the audit facts R1–R9), data-model.md, contracts/backup-coverage-doc.md, quickstart.md

**Tests**: No automated tests requested. Validation is the grep-based checks in `quickstart.md`
plus the existing repo gates (`python3 ci/check_syntax.py`, shellcheck from `ci/checks.yml`).

**Organization**: One deliverable file, built section by section. US1 = Coverage table,
US2 = Deliberately not backed up + Gaps, US3 = Restore order. Because every story edits the
same file, stories run in priority order, not in parallel.

**Hard constraints (apply to every task)**:
- Do NOT modify anything under `kopia/` (FR-010), `jenkins/`, `ci/jenkins/` or `.github/`
  (`manualMergePaths`; would block auto-merge). `jenkins/README.md` is NOT edited (research R6).
- No secret values anywhere: no keys, passwords, tokens, certificate material, SES forward
  address, or contents of secret files. Naming locations (`.env`, `secrets/`, `acme.json`) is fine (FR-014).
- State only what repo files show; write "cannot be determined from the repo" otherwise (FR-011).
- Whole document ≤ ~150 lines (FR-012). Links are relative.
- Quote `.kopiaignore` rules as their exact text in backticks, never by line number.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)

---

## Phase 1: Setup

**Purpose**: Re-verify the audit inputs against the current tree before writing.

- [X] T001 Re-read `kopia/.kopiaignore`, `kopia/README.md` ("What's running", "Restore from scratch") and `kopia/policies/*.json`, and confirm research.md R1/R2 still hold: three sources `/home/chad`, `/home/chad/.local/share/wave`, `/usr/local/bin`; gitignore semantics, last match wins, excluded dirs never entered. Note any drift in `specs/003-backup-coverage-doc/research.md` before continuing.
- [X] T002 [P] Re-check every stack's host locations against research.md R3 by reading `litellm/docker-compose.yml`, `monitoring/docker-compose.yml`, `traefik/docker-compose.yml` + `traefik/traefik.yml` (`acme.storage`), `serpbear/docker-compose.yml`, `homepage/docker-compose.yml`, `jenkins/docker-compose.yml` + `jenkins/README.md`, `hermes/README.md`, `decap/decap-server.service`, `gsc-mcp/.env.example`, `caddy/README.md`, and the deployed-files table in `docs/HOSTS.md` (fail2ban, sshd, sysctl, automation, kopia, monitoring host agents). Record any new path or named volume in `specs/003-backup-coverage-doc/research.md`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Document skeleton every story fills in.

- [X] T003 Create `docs/BACKUP-COVERAGE.md` with the contract's section skeleton in this order: `# Backup coverage (Kopia)`, intro (≤ 6 lines), `## Coverage`, `## Deliberately not backed up`, `## Gaps`, `## Restore order`, `## Not determinable from the repo`. Intro must state: the three sources (from `kopia/README.md`); rules use gitignore semantics, last matching rule wins, an excluded directory is never entered (so a nested `.kopiaignore` inside it is never read); Kopia does not read `.gitignore`; audit date 2026-09-26 and that `kopia/` was not changed; verdict meanings exactly as FR-002 (**yes** = in a source and nothing excludes it or its contents, at-any-depth build-artifact rules like `node_modules/` aside; **partly** = entered but named children excluded, or only named children re-included; **no** = excluded by a rule or outside every source).
- [X] T004 Add the update-trigger sentence to the intro of `docs/BACKUP-COVERAGE.md` (FR-015): update this document when a stack or app data directory is added, a compose mount or named volume changes, or `kopia/.kopiaignore` changes.

**Checkpoint**: skeleton exists; stories can fill sections.

---

## Phase 3: User Story 1 - See at a glance what is and isn't backed up (Priority: P1) 🎯 MVP

**Goal**: One table covering every service's host locations with a reproducible yes / no / partly verdict.

**Independent Test**: quickstart.md steps 1–3 and 9: exactly one header `| Service | Path | Holds | Backed up | Note |`; the stack loop for `litellm monitoring traefik serpbear homepage jenkins hermes decap gsc-mcp caddy fail2ban sshd sysctl automation kopia` prints nothing; any row's verdict can be re-derived from `kopia/.kopiaignore` by hand.

Row rules (data-model.md): Service = repo top-level dir name, first cell starts with it (e.g. `| litellm |`); Path is `~`-relative under `/home/chad`, absolute otherwise, named volumes as `~/.local/share/containers/storage/volumes/<name>`; Holds ≤ ~8 words; Backed up is exactly `yes`, `no` or `partly`; Note = deciding rule quoted in backticks, or "not in a backup source" / "git", or "cannot be determined from the repo". Same-verdict/same-reason rows of one service may be merged.

- [X] T005 [US1] Write the `## Coverage` table header `| Service | Path | Holds | Backed up | Note |` and the checkout rows in `docs/BACKUP-COVERAGE.md`: git-tracked config in `~/git/localsetup` = yes (no rule excludes `/git/`; also on the GitHub remote); state that git-ignored files in the checkout (`*/.env`, `traefik/logs/`, `monitoring/data/dashboards/`, `monitoring/prometheus/bearer_token`, `gsc-mcp/client_secrets.json`, `caddy/.env`) are backed up because Kopia does not read `.gitignore` (research R5).
- [X] T006 [US1] Add litellm rows to `docs/BACKUP-COVERAGE.md`: `litellm/litellm-config.yaml` + `litellm/.env` in the checkout = yes; named volumes `litellm_postgres_data` (virtual keys, budgets, spend), `litellm_redis_data` (cache), `litellm_logs` (proxy log) under `~/.local/share/containers/storage/volumes/` = no, rule `/.local/share/*` with no `!` re-include (research R4).
- [X] T007 [US1] Add monitoring rows to `docs/BACKUP-COVERAGE.md`: checkout bind mounts (`provisioning/`, `dashboards/`, `dashboards-otbla/`, `data/dashboards/`, `prometheus/bearer_token`, config files, `.env`) = yes; named volumes `monitoring_prometheus_data`, `monitoring_grafana_data`, `monitoring_loki_data` = no via `/.local/share/*`; `${GOOGLE_SA_KEY_PATH}` = cannot be determined from the repo (path only in untracked `.env`); host agents: promtail/logrotate units in `~/.config/systemd/user/` = yes (no rule), `~/.local/bin/promtail` = no via `/.local/*` (reinstallable).
- [X] T008 [US1] Add traefik rows to `docs/BACKUP-COVERAGE.md`: `traefik.yml`, `dynamic.yml`, `.env`, `logs/` in the checkout = yes; named volume `traefik_data` (`acme.json`: ACME account + certs) = no via `/.local/share/*`; `/etc/sysctl.d/99-unpriv-443.conf` belongs to the sysctl row.
- [X] T009 [US1] Add serpbear and homepage rows to `docs/BACKUP-COVERAGE.md`: `~/.local/share/serpbear/` (`data/`, `secrets/`) = yes via `!/.local/share/serpbear/`; `~/.local/share/homepage/config` = yes via `!/.local/share/homepage/`.
- [X] T010 [US1] Add jenkins rows to `docs/BACKUP-COVERAGE.md` (research R6): `~/.local/share/jenkins/` = partly — re-included by `!/.local/share/jenkins/`, then `/.local/share/jenkins/*` excludes all children except `!/.local/share/jenkins/ca/` and `!/.local/share/jenkins/secrets/` (yes); `~/.local/share/jenkins/data/` (JENKINS_HOME: build history, job state, `agent-pipeline/paused.json`, Jenkins' own `secrets/master.key`) = no; `jenkins/casc/` + `jenkins/.env` in the checkout = yes/git. Note in one line that `jenkins/README.md`'s nested `data/.kopiaignore` is never read because `data/` is not entered (README not edited here; belongs to #38).
- [X] T011 [US1] Add hermes and decap rows to `docs/BACKUP-COVERAGE.md`: `~/.hermes/` = partly (state/`config.yaml` kept; excluded children `/.hermes/hermes-agent/`, `/.hermes/tools/`, `/.hermes/bin/`, `/.hermes/cache/`, `/.hermes/lsp/`, `/.hermes/installs/`, `/.hermes/audio_cache/`, `/.hermes/image_cache/`, `/.hermes/logs/`, `/.hermes/*.bak*` — may be summarised as "install, caches, logs, backups excluded by the `/.hermes/…` rules" if the exact names are listed once); watchdog units in `~/.config/systemd/user/` = yes; decap unit in `~/.config/systemd/user/` = yes; `~/.npm-global/bin/decap-server` = no via `/.npm-global/` (reinstallable); the blog working copy it writes, `~/git/blogLosAngeles` = yes (no rule excludes `/git/`).
- [X] T012 [US1] Add gsc-mcp and caddy rows to `docs/BACKUP-COVERAGE.md`: `gsc-mcp/.env`, `gsc-mcp/client_secrets.json` in the checkout = yes; `caddy/` (archived) `.env` in the checkout = yes, note it is archived but still holds credentials (name only, no values).
- [X] T013 [US1] Add host drop-in rows to `docs/BACKUP-COVERAGE.md` from the `docs/HOSTS.md` deployed-files table: fail2ban, sshd, sysctl, automation `/etc/...` files (and `/etc/host-deploy/`, `/usr/local/sbin`) = no, "not in a backup source; git is the copy"; `/usr/local/bin` installs (`awsChadHomeIp.sh`, fail2ban exporter) = yes (source `/usr/local/bin`). One row per service, merging same-verdict paths.
- [X] T014 [US1] Add kopia rows to `docs/BACKUP-COVERAGE.md`: `~/.kopiaignore` (hardlink of `kopia/.kopiaignore`) = yes; `~/.config/kopia/repository.config` = yes (no rule) but useless without the repository password; `~/.config/autostart/` entry = yes; `~/.local/share/aws-roles-anywhere/` = yes via `!/.local/share/aws-roles-anywhere/` (place under the service that owns it per repo docs, or kopia/automation if unowned).
- [X] T015 [US1] Hand-verify every verdict in the Coverage table of `docs/BACKUP-COVERAGE.md` by walking `kopia/.kopiaignore` top to bottom for its path (last match wins; stop at the first excluded ancestor), then run quickstart.md steps 2–3 and fix any row that fails.

**Checkpoint**: US1 alone answers "is X backed up, and why?" (SC-001, SC-003).

---

## Phase 4: User Story 2 - Act on the gaps (Priority: P2)

**Goal**: Deliberate exclusions explained; Gaps listed with the exact excluding rule.

**Independent Test**: quickstart.md step 4 — every backticked rule in `## Gaps` passes `grep -qxF '<rule>' kopia/.kopiaignore`; Jenkins build history appears in the table and in "Deliberately not backed up", not in Gaps.

- [X] T016 [US2] Write `## Deliberately not backed up` in `docs/BACKUP-COVERAGE.md` as short bullets with reasons (FR-006, research R7): Jenkins `data/` build history and job state (rebuild needs only JCasC in git, `jenkins/.env` in the checkout and the kept `secrets/` + `ca/`; Jenkins' own `data/secrets/master.key` is not kept, so credentials come from JCasC and the mounted `secrets/` dir, not a restored `credentials.xml`); caches (`litellm_redis_data`, `~/.cache/`, hermes caches); logs and metrics history (`litellm_logs`, `monitoring_prometheus_data`, `monitoring_loki_data`); reinstallable installs/toolchains (`~/.local/bin/promtail`, `~/.npm-global/`, hermes install).
- [X] T017 [US2] Write `## Gaps` in `docs/BACKUP-COVERAGE.md`, one bullet each in the form **path** — what is lost — `excluding rule` (research R7): `~/.local/share/containers/storage/volumes/litellm_postgres_data` — virtual keys, budgets, spend — `/.local/share/*`; `…/monitoring_grafana_data` — Grafana DB: users, API tokens, UI-only state — `/.local/share/*`; `…/traefik_data` (`acme.json`) — ACME account and certs (re-issuable but rate-limited) — `/.local/share/*`. Add any further gap found in T001/T002 (for paths outside every source say "outside every backup source" instead of a rule). Add one closing line pointing to #38 for the fix.
- [X] T018 [US2] Run quickstart.md step 4 against `docs/BACKUP-COVERAGE.md` (extract each backticked rule from `## Gaps`, `grep -qxF` it in `kopia/.kopiaignore`) and fix mismatches.

**Checkpoint**: US1 + US2 give the #38 to-do list.

---

## Phase 5: User Story 3 - Know what to restore first (Priority: P3)

**Goal**: Short dependency-ordered restore list linking the Kopia runbook.

**Independent Test**: quickstart.md step 5 — every path restored *from* is a `yes`/`partly` row; step 1 names the Kopia repository password and S3 credentials as out-of-band; the section links `../kopia/README.md` and contains no kopia commands.

- [X] T019 [US3] Write `## Restore order` in `docs/BACKUP-COVERAGE.md` as a numbered list (research R8, FR-008): 1) out-of-band prerequisites no backup holds — Kopia repository password and S3 credentials (password manager; named, never valued) — then connect the repository; 2) `~/git/localsetup` (all stack `.env` files) and `~/.local/share/aws-roles-anywhere/`; 3) Traefik (edge; config + `.env` from the checkout, `acme.json` re-issued); 4) Jenkins (`~/.local/share/jenkins/ca/` + `secrets/`, JCasC from git; build history starts empty); 5) monitoring (config from checkout; Grafana DB state recreated by hand); 6) LiteLLM (config + `.env` restored; Postgres keys/budgets recreated by hand); 7) serpbear, homepage, hermes, decap. End with a relative link to [`../kopia/README.md`](../kopia/README.md) for the commands; do not repeat them.
- [X] T020 [US3] Cross-check each restore-from path in `## Restore order` of `docs/BACKUP-COVERAGE.md` against its Coverage row (must be `yes` or `partly`) and fix any mismatch.

**Checkpoint**: all three stories complete.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T021 Write `## Not determinable from the repo` in `docs/BACKUP-COVERAGE.md` (research R9, FR-011): Zuriel's host shares the rules but which of these paths exist there and its sources cannot be determined from the repo (one sentence, no rows); `${GOOGLE_SA_KEY_PATH}` location lives only in untracked `monitoring/.env`.
- [X] T022 [P] Add a docs-list entry to `README.md` next to the other `docs/*.md` bullets: `- **[docs/BACKUP-COVERAGE.md](docs/BACKUP-COVERAGE.md)** — what Kopia does and doesn't back up, per service: coverage table, gaps (for #38), restore order.` (FR-009)
- [X] T023 [P] Add one sentence to the Kopia bullets in `CLAUDE.md` "Stacks & conventions" (after the `kopia snapshot estimate` bullet): per-service coverage, gaps and restore order are in `docs/BACKUP-COVERAGE.md`; update it on a new stack or app data dir, a compose mount or named volume change, or any `kopia/.kopiaignore` change (FR-009, FR-015).
- [X] T024 Trim `docs/BACKUP-COVERAGE.md` to ≤ ~150 lines (`wc -l`), merging same-verdict rows per data-model.md if needed, and scan it for secret values (FR-012, FR-014; `gitleaks detect --no-git --source docs/BACKUP-COVERAGE.md` if gitleaks is available, else manual review).
- [X] T025 Run all quickstart.md checks from the repo root: steps 1–11, including `git diff --stat main -- kopia/ jenkins/ ci/jenkins/ .github/` → empty, `python3 ci/check_syntax.py`, and the shellcheck command from `ci/checks.yml`. Fix the doc (never the gates) on failure.
- [X] T026 Confirm `docs/monitoring.drawio` needs no change (no component or data flow change, per plan Constitution Check IX) and record any new implementation-time decisions in the `## Assumptions` section of `specs/003-backup-coverage-doc/spec.md`.

---

## Dependencies & Execution Order

- **Setup (T001–T002)**: T002 [P] with T001 (different inputs, both read-only).
- **Foundational (T003–T004)**: after Setup; creates the file all stories edit.
- **US1 (T005–T015)**: after T004. Sequential (same file). MVP.
- **US2 (T016–T018)**: after US1 — Gaps are the `no`/`partly` rows of the table.
- **US3 (T019–T020)**: after US1 (restore paths must match table verdicts); independent of US2 in content but same file, so run after it.
- **Polish**: T021 after T003; T022 and T023 [P] can run any time after T003 (different files); T024–T026 last.

### Story independence

- US1 is independently useful (the audit).
- US2 and US3 depend on US1's verdicts by design (spec: Gaps and restore paths are derived from the table), but not on each other.

## Parallel Example

```text
# Setup, read-only:
T001 (kopia rules/sources)  ||  T002 (stack host locations)

# Link edits, different files, any time after T003:
T022 README.md  ||  T023 CLAUDE.md
```

## Implementation Strategy

### MVP (US1 only)

1. T001–T004 → skeleton.
2. T005–T015 → Coverage table, verified by hand and by quickstart steps 1–3.
3. Stop and validate: any stack dir answers "backed up? why?" in under a minute.

### Incremental delivery

1. + US2 (T016–T018) → #38 to-do list with verbatim rules.
2. + US3 (T019–T020) → restore order.
3. Polish (T021–T026) → links, length, secrets scan, gates.

Single PR; commit after each phase is fine.
