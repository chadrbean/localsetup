# Data Model: Blog Pipeline Visibility & Right-Sized Gating

**Phase 1 output for** [plan.md](plan.md). The entities come from the spec's Key Entities section. Storage is files in git plus Jenkins build records; there is no database.

## Check (catalog entry)

**Stored in:** `blogLosAngeles/ci/checks.yml`, one entry per check. The schema is in [contracts/check-catalog.md](contracts/check-catalog.md).

| Field | Type | Rules |
|---|---|---|
| `id` | string, kebab-case | Unique. Matches the `runCheck('<id>')` call or the smoketest stem (`check_<id_with_underscores>.py`). |
| `stage` | enum | One of the stage ids in [contracts/delivery-stages.md](contracts/delivery-stages.md), or a site-health job id. |
| `category` | enum `blocking \| advisory \| monitoring` | Must satisfy FR-002: `monitoring` checks never appear in the `delivery` job. |
| `scope` | list of path prefixes, optional | If set, the check is `blocking` only when the change touches one of these paths. Otherwise it is treated as `advisory`. It is ignored on cron and manual runs, where the check is always treated as `advisory`. |
| `threshold` | string | A human-readable pass rule, e.g. `aggregate >= 85 and 0 indexability violations`. |
| `runs_on` | list of `pr \| main \| cron \| after-deploy \| weekly \| daily` | Must be consistent with the stage's own triggers. |
| `purpose` | string ≤ 120 chars | What the check protects. |
| `command` | string, optional | Shell entry point, for documentation and for agent-validate. |
| `waiver` | enum `exceptions-file \| override-only \| none` | How to bypass the check temporarily. |

**Validation:** `check_catalog_coverage.py` enforces all of the following:
- every `scripts/smoketests/check_*.py` has an entry
- every `runCheck('x')` in `ci/jenkins/*.Jenkinsfile` has an entry
- every entry resolves to something that exists
- `docs/ci-gates.md` equals `render_catalog.py` output

## Stage

These are fixed and ordered, and defined in [contracts/delivery-stages.md](contracts/delivery-stages.md).

A stage has a state per run, which pipeline-graph-view renders:
`not-started → running → {success | unstable | failure | skipped | aborted}`

These map to the spec's display states:

| Spec state | Jenkins state |
|---|---|
| waiting | not-started |
| running | running |
| passed | success |
| passed with warnings | unstable, with a warning-reason badge |
| failed | failure |
| errored | failure, with an "errored:" badge |
| skipped (with reason) / not applicable | skipped, with the reason in the stage summary |

## Change (run)

A Jenkins build of `blogLosAngeles/delivery/<branch>`.

| Attribute | Source |
|---|---|
| trigger | `triggeredBy()`: `scm`, `cron`, `manual` or `upstream` |
| change type | derived from `changedFiles()`: `site`, `terraform`, `automation`, `ci` or `other` (a set) |
| overall result | the Jenkins build result |
| blocking check | build badge and description set by `runCheck` on the first blocking FAILURE |
| override | `OVERRIDE_REASON` parameter + user, as a badge and description |

Build history retention stays at `buildDiscarder(logRotator(numToKeepStr:'60', daysToKeepStr:'90'))`, which is required by `check_artifact_cleanup`.

## Verdict

One per check per run. It is produced by `runCheck`, following [contracts/check-result-contract.md](contracts/check-result-contract.md).

| Attribute | Type |
|---|---|
| check id | string |
| exit code | 0–4 |
| result | `passed \| warned \| failed \| errored \| inconclusive \| n/a` |
| effective stage result | SUCCESS / UNSTABLE / FAILURE |
| details | a log excerpt plus report links (SARIF/JUnit through `publishReports`) |

## Waiver

Stored in `blogLosAngeles/.security/exceptions.json`. The schema is unchanged.

| Field | Rules |
|---|---|
| `id`, `tool`, `rule`, `finding`, `reason`, `expires` | Existing fields. `expires` must be ≤ 90 days out. |

The validation state changes as the expiry date approaches:

`valid → expiring (≤ 14 days, WARN) → expired (FAIL)`

Separately, a waiver becomes `stale (WARN)` when `finding`'s path no longer exists.

## Override

This is not stored separately. It is recorded on the Jenkins run through a parameter, a badge, the description and an email. Constraints: manual trigger, the `main` branch, and a non-empty reason.
