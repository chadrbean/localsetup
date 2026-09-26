# Implementation Plan: Backup coverage audit (docs/BACKUP-COVERAGE.md)

**Branch**: `003-backup-coverage-doc` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/003-backup-coverage-doc/spec.md`

## Summary

Add `docs/BACKUP-COVERAGE.md`: one table of every stack's host locations with a yes / no /
partly Kopia verdict, then deliberate exclusions, Gaps (with the verbatim `.kopiaignore`
line), a Restore order linking `kopia/README.md`, and what can't be determined from the
repo. Link it from `README.md` and `CLAUDE.md`. Documentation only; nothing under `kopia/`
changes. The audit facts are already gathered in [research.md](research.md).

## Technical Context

**Language/Version**: Markdown (GitHub-flavoured). No code.

**Primary Dependencies**: none. Inputs are repo files: `kopia/.kopiaignore`,
`kopia/policies/*.json`, `kopia/README.md`, each stack's compose file and README,
`docs/HOSTS.md`.

**Storage**: N/A.

**Testing**: the manual checks in [quickstart.md](quickstart.md) (grep-based) plus the
existing gates `python3 ci/check_syntax.py` and the shellcheck check in `ci/checks.yml`.

**Target Platform**: host `wkspikaoschad` (`/home/chad`); Zuriel's host only as "not
determinable".

**Project Type**: documentation / runbook.

**Performance Goals**: reader answers "is X backed up, and why not?" in < 1 minute (SC-003).

**Constraints**: ≤ ~150 lines; no secret values; no edits under `kopia/`; no edits under
`jenkins/`, `ci/jenkins/` or `.github/` (they would block the agent pipeline's auto-merge,
`manualMergePaths`).

**Scale/Scope**: 15 stack directories, ~30 table rows.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Result | Why |
|---|---|---|
| I. Everything as code | PASS | Doc describes git-tracked config; no out-of-band change. |
| II. Secrets & short-lived creds | PASS | Names secret *locations* only (`.env`, `secrets/`), never values. |
| III. Sensitive-data minimisation | PASS | No logging change; LiteLLM DB is only described. |
| IV. Catalog-driven gates | PASS | No gate added or changed; existing catalog checks still run. |
| V. Contained agents | PASS | Doc-only; nothing touches the gate, allowlist or `manualMergePaths`. |
| VI. Rootless, local-first stacks | PASS | Documents the `~/.local/share/<app>/` convention and where named volumes actually live; no stack change. |
| VII. Verified observability | PASS (N/A) | No dashboard or alert change. |
| VIII. Cost-aware routing | PASS (N/A) | No AI routing change. |
| IX. Docs & contracts current | PASS | README.md and CLAUDE.md link the new doc; `docs/monitoring.drawio` unchanged because no component or data flow changes (only a description of existing backup coverage). Syntax and shellcheck gates stay green. |

Post-design re-check (after Phase 1): unchanged, all PASS. No Complexity Tracking entries.

## Project Structure

### Documentation (this feature)

```text
specs/003-backup-coverage-doc/
├── plan.md              # this file
├── research.md          # Phase 0: the audit facts (sources, locations, verdicts)
├── data-model.md        # Phase 1: row/section model
├── quickstart.md        # Phase 1: validation steps
├── contracts/
│   └── backup-coverage-doc.md   # required document structure
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
docs/BACKUP-COVERAGE.md   # new
README.md                 # + docs-list entry
CLAUDE.md                 # + one line in "Stacks & conventions"
```

**Structure Decision**: one new doc plus two link edits. No code, no `kopia/` changes.

## Key design decisions (from research)

- Three backup sources (`/home/chad`, `~/.local/share/wave`, `/usr/local/bin`), so
  `/usr/local/bin` installs are covered; `/etc` drop-ins are "outside every backup source,
  git is the copy" (R1).
- Named volumes live in `~/.local/share/containers/storage/volumes/` (stated in the repo for
  `litellm_logs`) and are all excluded by `/.local/share/*` (R4). Gaps: LiteLLM Postgres,
  Grafana DB, Traefik `acme.json` (R7).
- The checkout `~/git/localsetup` is backed up, including git-ignored `.env` files and
  `traefik/logs` — the restore path for stack secrets (R5).
- Jenkins is `partly`; the doc notes that `jenkins/README.md`'s nested
  `data/.kopiaignore` claim is moot because `data/` is never entered, without editing
  `jenkins/` (R6).
- Restore order step 1 is the out-of-band bootstrap (Kopia repository password, S3
  credentials, named only), then the backed-up paths; gap services (LiteLLM DB, Grafana DB)
  stay in the list with "recreate by hand" (R8, FR-008).
- No secret values anywhere in the doc; locations only (FR-014). The doc and its CLAUDE.md
  line state the update trigger (FR-015).

## Complexity Tracking

None.
