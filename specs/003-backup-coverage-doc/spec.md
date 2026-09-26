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

**Independent Test**: Every path named in the restore order is marked "yes" or "partly" in
the table, and the section links to the Kopia runbook instead of repeating commands.

**Acceptance Scenarios**:

1. **Given** the restore order, **When** the reader follows it, **Then** services that
   others depend on (reverse proxy, secrets/certificates, CI) are ordered before dependents.

---

### Edge Cases

- A stack with no compose file but with host-installed files (systemd units, sshd/sysctl
  drop-ins, fail2ban config): covered as "configuration lives in git" plus any host path it
  reads or writes.
- A location that is backed up only through a re-include of one child (e.g. Jenkins
  `ca/` and `secrets/`) is "partly", with the included children named.
- A rule pattern like `/x/**` + `!/x/y/**` that looks like it keeps a child but does not,
  because Kopia never enters an excluded directory: reported as "no".
- Paths that belong to the second desktop (Zuriel's host) or to named volumes whose host
  location isn't in the repo: stated as undeterminable from the repo.
- Configuration that is tracked in this git repo: noted as recoverable from git, independent
  of Kopia, but only if the repo's own checkout location is backed up or the remote exists.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The change MUST add `docs/BACKUP-COVERAGE.md`.
- **FR-002**: The document MUST contain one table with the columns service, path, what it
  holds, backed up (yes / no / partly) and note.
- **FR-003**: The table MUST cover every stack directory in the repo that runs a service or
  has a compose file or bind mounts — at least `litellm/`, `monitoring/`, `traefik/`,
  `serpbear/`, `homepage/`, `jenkins/`, `hermes/`, plus any other such directory found
  (e.g. `caddy/`, `decap/`, `fail2ban/`, `gsc-mcp/`, `automation/`).
- **FR-004**: Host locations MUST be taken from the compose bind mounts, host-installed
  files documented in the repo, and the `~/.local/share/<app>/` convention.
- **FR-005**: Verdicts MUST follow the ignore rules exactly as the backup tool applies them:
  gitignore semantics, last matching rule wins, and an excluded directory is never entered.
- **FR-006**: The document MUST explain what is deliberately not backed up and why,
  including that Jenkins build history is excluded while the configuration and credentials
  needed to rebuild Jenkins and its pipelines are kept (or are in git).
- **FR-007**: A **Gaps** section MUST list every location holding configuration or data
  worth keeping that is not covered, each with the exact ignore line that excludes it (or a
  note that no rule covers it because the path is outside the backup source).
- **FR-008**: A short **Restore order** section MUST name which service to recover first and
  from which path, and MUST link to `kopia/README.md` for commands rather than repeat them.
- **FR-009**: `README.md` (docs list) and `CLAUDE.md` (Stacks & conventions) MUST link to the
  new document.
- **FR-010**: The change MUST NOT modify anything under `kopia/` (ignore file, policies,
  scripts).
- **FR-011**: The document MUST state only what the repo files show and say "cannot be
  determined from the repo" where that applies.
- **FR-012**: The document SHOULD stay under about 150 lines.
- **FR-013**: The repo's syntax check and shell-lint check MUST still pass.

### Key Entities

- **Service / stack directory**: a repo directory whose contents run or configure something
  on a host.
- **Host location**: a path on the host holding a service's persistent data, secrets or
  configuration.
- **Ignore rule**: one line of the shared backup ignore file; its position matters.
- **Coverage verdict**: yes / no / partly, with the rule(s) that produce it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of stack directories that run a service or bind-mount host paths appear
  in the table.
- **SC-002**: Every gap entry quotes an ignore line that exists verbatim (0 mismatches when
  checked by search), or explicitly says the path is outside the backup source.
- **SC-003**: A reader can answer "is service X's data backed up, and if not why?" for any
  service in under one minute using only the document.
- **SC-004**: The document is at most ~150 lines, and zero files under `kopia/` change.
- **SC-005**: The existing repo checks (syntax and shell lint) pass unchanged.

## Assumptions

- **Branch creation**: Created branch `003-backup-coverage-doc` by hand — no spec-kit git
  hook is installed (`.specify/extensions.yml` absent), and work must not happen on `main`.
- **Backup source**: The Kopia source is the home directory (`/home/chad`) per
  `kopia/policies/` and the ignore file header; paths outside it (e.g. `/etc`,
  `/usr/local/bin`) are reported as "not in the backup source" rather than as gaps with an
  ignore line — the issue asks for the exact line, and none exists for those.
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
