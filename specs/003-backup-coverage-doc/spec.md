# Feature Specification: Backup coverage audit (docs/BACKUP-COVERAGE.md)

**Feature Branch**: `003-backup-coverage-doc`

**Created**: 2026-09-26

**Status**: Draft

**Input**: User description: "Document what Kopia does and doesn't back up, per service (docs/BACKUP-COVERAGE.md)" — GitHub issue chadrbean/localsetup#63, part of #38 (item 4 and the audit behind items 1 and 2).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See at a glance what is and isn't backed up (Priority: P1)

The owner (or an agent working on #38) opens one document and, for every service this repo
runs, sees where its persistent data and configuration live on the host and whether the
backup covers each location (yes / no / partly), with a short note explaining the verdict.

**Why this priority**: This is the audit itself. Without it, gaps are only found during a
failed restore.

**Independent Test**: Pick any stack directory in the repo; its locations appear in the
table, and each verdict can be reproduced by reading the ignore rules and policies by hand.

**Acceptance Scenarios**:

1. **Given** the repo's stack directories, **When** the reader scans the table, **Then**
   every directory that runs a service or bind-mounts host paths has at least one row.
2. **Given** a row marked "yes", "no" or "partly", **When** the reader applies the ignore
   rules in order (last match wins; an excluded directory is never entered), **Then** they
   reach the same verdict.
3. **Given** a location whose contents live on another host or can't be seen from the repo,
   **When** the reader looks at its row, **Then** it says the value cannot be determined
   from the repo instead of guessing.

---

### User Story 2 - Act on the gaps (Priority: P2)

The person fixing #38 reads a **Gaps** section that lists each location holding
configuration or data worth keeping that the backup does not cover, together with the exact
ignore line responsible.

**Why this priority**: Turns the audit into a to-do list for #38 without changing the
backup rules in this change.

**Independent Test**: For each listed gap, the quoted line exists verbatim in the ignore
file and is the rule that excludes the path.

**Acceptance Scenarios**:

1. **Given** a gap entry, **When** the reader searches the ignore file for the quoted line,
   **Then** it is found verbatim.
2. **Given** a location deliberately excluded (for example Jenkins build history), **When**
   the reader looks for it, **Then** it is in the table as "no" with the reason, not in Gaps.

---

### User Story 3 - Know what to restore first (Priority: P3)

After losing the host, the owner reads a short **Restore order** that says which service to
recover first and from which backed-up path, and follows a link to the Kopia runbook for
the actual commands.

**Why this priority**: Useful only once a disaster happens; the audit and gaps come first.

**Independent Test**: Every path the restore order says to restore *from* is marked "yes" or
"partly" in the table, and the section links to the Kopia runbook instead of repeating commands.

**Acceptance Scenarios**:

1. **Given** the restore order, **When** the reader follows it, **Then** services that
   others depend on (reverse proxy, secrets/certificates, CI) are ordered before dependents.
2. **Given** a fresh host, **When** the reader starts the restore order, **Then** its first
   step names what must come from outside every backup (the Kopia repository password and
   the S3 credentials) before anything can be restored.
3. **Given** a service whose data is a gap (e.g. LiteLLM's database), **When** the reader
   reaches its step, **Then** it says what is restored (config, `.env`) and what must be
   recreated by hand.

---

### Edge Cases

- A stack with no compose file but with host-installed files (systemd units, sshd/sysctl
  drop-ins, fail2ban config): covered as "configuration lives in git" plus any host path it
  reads or writes.
- A location that is backed up only through a re-include of one child (e.g. Jenkins
  `ca/` and `secrets/`) is "partly", with the included children named.
- A rule pattern like `/x/**` + `!/x/y/**` that looks like it keeps a child but does not,
  because Kopia never enters an excluded directory: reported as "no".
- Paths that belong to the second desktop (Zuriel's host), or whose location is only in an
  untracked `.env` (e.g. `GOOGLE_SA_KEY_PATH`): stated as undeterminable from the repo.
  Rootless-podman named volumes are *not* in this class: the repo states their storage root
  (`~/.local/share/containers/storage/volumes/`), so they get a normal verdict.
- A secret that sits inside an excluded directory (e.g. Jenkins' own `secrets/master.key`
  under `data/`): reported with its directory's verdict, and the document says what replaces
  it on a rebuild.
- Files that git ignores but that sit in a backed-up checkout (`.env`, logs): judged by the
  Kopia rules only, because Kopia does not read `.gitignore`.
- Configuration that is tracked in this git repo: noted as recoverable from git, independent
  of Kopia, but only if the repo's own checkout location is backed up or the remote exists.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The change MUST add `docs/BACKUP-COVERAGE.md`.
- **FR-002**: The document MUST contain one table with the columns service, path, what it
  holds, backed up (yes / no / partly) and note. Verdicts mean: **yes** = inside a backup
  source and no rule excludes it or its contents (at-any-depth build-artifact rules such as
  `node_modules/` aside); **partly** = the directory is entered but named children are
  excluded, or only named children are re-included (the note names them); **no** = an ignore
  rule excludes it or it is outside every backup source.
- **FR-003**: The table MUST cover every top-level repo directory that has a compose file,
  a bind mount, a named volume, or installs files on a host (`docs/HOSTS.md`) — at least `litellm/`, `monitoring/`, `traefik/`,
  `serpbear/`, `homepage/`, `jenkins/`, `hermes/`, plus any other such directory found
  (e.g. `caddy/`, `decap/`, `fail2ban/`, `gsc-mcp/`, `automation/`, `sshd/`, `sysctl/`,
  `kopia/`). `ci/`, `scripts/`, `docs/` and `specs/` are not services; an installed script
  is covered under its installed path.
- **FR-004**: Host locations MUST be taken from the compose bind mounts, host-installed
  files documented in the repo, and the `~/.local/share/<app>/` convention.
- **FR-005**: Verdicts MUST follow the ignore rules exactly as the backup tool applies them:
  gitignore semantics, last matching rule wins, and an excluded directory is never entered.
- **FR-006**: The document MUST explain what is deliberately not backed up and why,
  including that Jenkins build history is excluded while the configuration and credentials
  needed to rebuild Jenkins and its pipelines are kept (or are in git), and that Jenkins'
  own `data/secrets/` (master key) is not kept, so credentials come from JCasC and the
  mounted `secrets/` directory rather than from restored `credentials.xml`.
- **FR-007**: A **Gaps** section MUST list every location holding configuration or data
  worth keeping that is not covered, each with the exact ignore line that excludes it (or a
  note that no rule covers it because the path is outside the backup source).
- **FR-008**: A short **Restore order** section MUST name which service to recover first and
  from which path, and MUST link to `kopia/README.md` for commands rather than repeat them.
  Its first step MUST name the out-of-band prerequisites that no backup holds (Kopia
  repository password, S3 credentials) without giving their values. A service whose data
  is a gap is still listed, saying what is restored and what must be recreated.
- **FR-009**: `README.md` (docs list) and `CLAUDE.md` (Stacks & conventions) MUST link to the
  new document.
- **FR-010**: The change MUST NOT modify anything under `kopia/` (ignore file, policies,
  scripts).
- **FR-011**: The document MUST state only what the repo files show and say "cannot be
  determined from the repo" where that applies.
- **FR-012**: The document SHOULD stay under about 150 lines.
- **FR-013**: The repo's syntax check and shell-lint check MUST still pass.
- **FR-014**: The document MUST NOT contain secret values (keys, passwords, tokens,
  certificate material, the SES forward address) or the contents of secret files; it may
  name where secrets live (`.env`, `secrets/`, `acme.json`).
- **FR-015**: The document MUST say when it has to be updated: a new stack or app data
  directory, a changed compose mount or named volume, or any `kopia/.kopiaignore` change.
  The CLAUDE.md line from FR-009 MUST carry the same rule.

### Key Entities

- **Service / stack directory**: a repo directory whose contents run or configure something
  on a host.
- **Host location**: a path on the host holding a service's persistent data, secrets or
  configuration.
- **Ignore rule**: one line of the shared backup ignore file; its position matters.
- **Coverage verdict**: yes / no / partly, with the rule(s) that produce it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the directories FR-003 defines (compose file, bind mount, named volume
  or host-installed files) appear in the table.
- **SC-002**: Every gap entry quotes an ignore line that exists verbatim (0 mismatches when
  checked by search), or explicitly says the path is outside the backup source.
- **SC-003**: A reader can answer "is service X's data backed up, and if not why?" for any
  service in under one minute using only the document.
- **SC-004**: The document is at most ~150 lines, and zero files under `kopia/` change.
- **SC-005**: The existing repo checks (syntax and shell lint) pass unchanged.

## Assumptions

- **Branch creation**: Created branch `003-backup-coverage-doc` by hand — no spec-kit git
  hook is installed (`.specify/extensions.yml` absent), and work must not happen on `main`.
- **Backup source**: Paths outside every Kopia source (e.g. `/etc`) are reported as "outside
  every backup source" rather than as gaps with an ignore line — the issue asks for the
  exact line, and none exists for those. (The first draft named `/home/chad` as the only
  source; superseded by "Backup sources (plan)" below.)
- **Repo checkout as backup of config**: Git-tracked configuration counts as recoverable
  from the GitHub remote; whether the local checkout under `~/git/` is also in Kopia is
  judged from the ignore rules like any other path.
- **"Worth keeping"**: Secrets (`.env`, certificates), app databases and state that cannot be
  regenerated are worth keeping; caches, logs, re-downloadable images and CI build history
  are not — matching the ignore file's own section comments.
- **Extra stack directories**: `caddy/`, `decap/`, `fail2ban/`, `gsc-mcp/`, `automation/`,
  `sshd/`, `sysctl/` are included when they install files or keep state on a host; pure
  host-config drop-ins get one row noting that git is their source of truth.
- **Zuriel's host**: Only its Kopia rules (shared file) are knowable from the repo; what data
  actually exists there is stated as undeterminable.
- **Doc links**: README gets an entry in its docs list; CLAUDE.md gets one line in
  "Stacks & conventions" next to the Kopia bullet.
- **Backup sources (plan)**: Three sources, not one — `/home/chad`, `~/.local/share/wave`,
  `/usr/local/bin` (`kopia/README.md`) — so `/usr/local/bin` installs count as backed up;
  `/etc` drop-ins are "outside every backup source". — the README is the repo's record of sources.
- **Named volumes (plan)**: Reported under `~/.local/share/containers/storage/volumes/<name>`
  and judged "no" via `/.local/share/*`, not "undeterminable". — the repo states that path for
  `litellm_logs` (promtail config, `docs/USAGE.md`), and all stacks share one rootless podman.
- **Git-ignored files in the checkout (plan)**: `.env` files, `traefik/logs` etc. under
  `~/git/localsetup` are "yes". — Kopia doesn't read `.gitignore` and no rule excludes `/git/`.
- **jenkins/README.md discrepancy (plan)**: Its claim that a nested `data/.kopiaignore`
  applies is noted in the new doc but `jenkins/README.md` is not edited. — `data/` is never
  entered; `jenkins/` is in `manualMergePaths` and would block auto-merge; fix belongs to #38.
- **drawio (plan)**: `docs/monitoring.drawio` is not changed. — no component or data flow changes.
- **Checklist domains (checklist)**: Requirements reviewed for data coverage and security
  (`checklists/data.md`, `checklists/security.md`). — the feature is an audit of where data
  and secrets live; there is no UI, API or performance surface.
- **Retention and schedule (checklist)**: Out of scope; the doc covers *what* is backed up,
  not how often or how long. — `kopia/README.md` already documents both; repeating them
  would drift.
- **Restore bootstrap (checklist)**: The restore order starts with the Kopia repository
  password and S3 credentials from outside the backup, named but never valued. —
  `kopia/README.md` says the password can't be recovered and `repository.config` isn't in git.
- **Naming secret locations publicly (checklist)**: Allowed; values never. — the locations
  are already in tracked READMEs and `.env.example` files, so naming them adds no exposure.
- **Gap services in restore order (checklist)**: Listed with what is restored and what is
  recreated, instead of dropped. — the owner needs to know LiteLLM keys and Grafana state
  are rebuilt by hand.
- **Update trigger (checklist)**: The doc and its CLAUDE.md line say to update it on a new
  stack/data dir, mount or volume change, or `.kopiaignore` change. — otherwise the audit
  silently goes stale like the `jenkins/README.md` claim did.
- **Checkout row (implement)**: The table starts with a `localsetup (checkout)` row for
  `~/git/localsetup` before the per-stack rows. — the checkout is the restore path for every
  stack's `.env`, and FR-003's stack loop still finds each stack's own rows.
- **`${GOOGLE_SA_KEY_PATH}` (implement)**: Not given a table row; the monitoring checkout row points
  to "Not determinable from the repo". — a row needs a yes/no/partly verdict and none can be
  derived from the repo (FR-011), so a guessed verdict would mislead.
- **aws-roles-anywhere placement (implement)**: Listed under `jenkins`. — the cert is issued by
  `scripts/jenkins_ca.sh --host` from the Jenkins CA; `scripts/` is not a service.
- **Monitoring LAN firewall (implement)**: Added as a `no` row (outside every source, git is the copy).
  — found in the `docs/HOSTS.md` deployed-files table during the T002 re-check.
- **Local gate run (implement)**: `python3 ci/check_syntax.py` (no PyYAML, no pip) and shellcheck
  (not installed) could not run in the agent container; the change touches only `.md` files,
  which neither gate reads, and the pipeline's Validate stage runs both. — gates left in place.
- **drawio (implement)**: `docs/monitoring.drawio` unchanged, confirmed. — no component or data flow change.
