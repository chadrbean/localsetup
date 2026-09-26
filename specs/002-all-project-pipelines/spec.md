# Feature Specification: Pipeline Visibility & Right-Sized Gating for All Projects

**Feature Branch**: `docs/pipeline-visibility-all`

**Created**: 2026-09-26

**Status**: Draft

**Input**: User description: "I want to do the same things we did for blogLosAngeles for our pipelines and observability for the other projects in jenkins and grafana. 1. run through all the speckit stages on auto and without asking. 2. analyze each project and implement a better pipeline organization and functionality like we did for blog. 3. do all the validation testing, restarts of infrastructure and fixes until this is completed and working 4. commit push pr merge at will"

Spec 001 (`specs/001-blog-pipeline-visibility`) made the blog's pipelines right-sized, ordered and visible. This spec applies the same outcomes to the other projects in Jenkins:

- **aws-infrastructure**: the shared AWS account's Terraform.
- **zca-accounting**: the accounting app.
- **localsetup**: this host's configuration.
- **The CI platform's own maintenance jobs.**

It also adds one cross-project view and alerting in Grafana. TraderIntel is out of scope.

## Current State (baseline, 2026-09-26)

Build history was read from the Jenkins data on disk, covering every build since the Jenkins cut-over on 2026-09-24.

| Project / process | Runs | Passed | Unstable | Failed | Skipped / not built | Aborted |
|---|---|---|---|---|---|---|
| aws-infrastructure terraform (main) | 7 | 2 | 0 | 4 | 1 | 0 |
| aws-infrastructure drift (main) | 3 | 2 | 0 | 0 | 1 | 0 |
| localsetup ci (main) | 8 | 1 | 7 | 0 | 0 | 0 |
| zca-accounting ci (main) | 8 | 0 | 0 | 1 | 7 | 0 |
| zca-accounting ci (PR-97) | 14 | 0 | 0 | 7 | 5 | 2 |
| zca-accounting deploy-dev (main) | 8 | 0 | 0 | 1 | 7 | 0 |
| zca-accounting deploy-prod (main) | 7 | 0 | 0 | 0 | 7 | 0 |
| zca-accounting local-refresh | 0 | — | — | — | — | — |
| ci-maintenance aws-role-smoke | 5 | 5 | 0 | 0 | 0 | 0 |
| ci-maintenance cert-expiry | 0 (first scheduled run 2026-09-28) | — | — | — | — | — |

Observed root causes:

1. **aws-infrastructure**
   - Security scanners over-blocked on deliberate design choices. They have since been waived one by one.
   - When a scanner reports findings, the run stops *before* the plan is posted to the pull request. The reviewer then loses the one thing they need.
   - One failure was a race with the drift job over the shared state lock. It has been fixed.
   - The drift job reports **success when it finds drift**, so drift is only noticed if someone reads an email or an issue.
   - The drift job also runs for pull requests, although it only makes sense against `main`.
2. **localsetup**
   - `ci` has been **"unstable" (yellow) on 7 of 8 runs** because of two deliberate container-configuration findings: the build image runs as root on purpose.
   - The "no new issues" rule compares each run against the last run that passed that rule. Because that run never comes, the yellow is permanent.
   - Pull requests are never compared against `main`.
3. **zca-accounting**
   - The project's constitution (Principle XX, NON-NEGOTIABLE) makes every pipeline manual-only. Every push therefore records one **"not built"** entry in each of three jobs; 21 of 23 main entries are skip noise.
   - The manual-only guard lets branch-indexing runs through. Some PR runs executed or failed when they should have been skipped.
   - Five PR runs failed on "not mergeable" checkout errors before any check ran.
   - The deploy jobs still hold stale PR branches.
   - The local stack refresh job has never run.
   - Real defects are mixed with advisory findings in one undifferentiated pass/fail:
     - Real: a coverage floor miss at 68.9% against 70%.
     - Advisory-grade:
       - lint deprecations
       - diagram-currency
       - commit-message case
       - an upstream vulnerability-feed finding
       - a 48-minute end-to-end suite that fails mostly for environmental reasons
4. **Maintenance jobs**
   - The role smoke test offers a production role that does not exist.
   - Certificate expiry has no category and no alert beyond email.
5. **Observability**
   - Only the blog has CI panels and a CI alert in Grafana. The metrics already exist for every job, but nothing shows the whole estate or alerts on another project's `main` failing.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Only real defects turn a project red (Priority: P1)

The maintainer pushes a change to any project. The run turns red (failed) only if the change itself would ship something broken, insecure or out of policy. Deliberate, reviewed exceptions, style drift, process reminders, flaky environments and outside advisory feeds show as warnings, never as a failure or a permanent yellow.

**Why this priority**: Red that doesn't mean "broken" trains the maintainer to ignore red, and that is how real defects get through. This is the direct cause of the permanent yellow on localsetup and the stopped plan comments on aws-infrastructure.

**Independent Test**: Run each project's per-change pipeline on `main` with no code change. The result must be green, or yellow only with a named advisory finding. It must not be red, and not yellow for a reason already accepted.

**Acceptance Scenarios**:

1. **Given** localsetup has two reviewed, intentional container findings, **When** `ci` runs on `main`, **Then** the run is green and the findings stay visible as accepted exceptions.
2. **Given** an aws-infrastructure pull request whose scanners report findings, **When** the pipeline runs, **Then** the plan is still produced and posted to the pull request, and the findings show on the same run.
3. **Given** a zca-accounting run where only advisory checks fail (lint deprecations, diagram currency, commit-message case, end-to-end environment flakiness), **When** the run finishes, **Then** it is yellow with the advisory checks named, not red.
4. **Given** a zca-accounting change that drops test coverage below the constitution's floor, **When** the run finishes, **Then** it is red and names the coverage check.
5. **Given** an outside advisory feed (vulnerability database, provider download site) is unreachable, **When** a check depends on it, **Then** the check reports "inconclusive", not "failed".

---

### User Story 2 - One screen shows the health of every project (Priority: P1)

The maintainer opens one Grafana dashboard. They see, for every project and job, the latest `main` result, which stage failed, when each job last ran and last passed, and whether any scheduled job has gone quiet. Alerts arrive when a project's `main` goes red, when a monitoring job fails, or when a scheduled job stops running.

**Why this priority**: Today only the blog is visible. Everything else needs a Jenkins page per job, and a quietly broken drift or certificate job would go unnoticed for weeks.

**Independent Test**: Break one check on one project's `main` and wait one scrape interval. The dashboard shows that project red with the failing stage named, and an alert email arrives.

**Acceptance Scenarios**:

1. **Given** all projects are green, **When** the maintainer opens the cross-project dashboard, **Then** every in-scope job appears with its latest `main` result, last-run age and last-success age.
2. **Given** aws-infrastructure's `main` pipeline fails in its plan stage, **When** the dashboard refreshes, **Then** the failed stage is shown by name, and the "CI main failing" alert fires within 15 minutes.
3. **Given** the monthly drift check has not run for more than 35 days, **When** alerting evaluates, **Then** a "scheduled job stale" alert fires.
4. **Given** the drift check finds real infrastructure drift, **When** it finishes, **Then** it is red on the dashboard and alerts. It no longer shows green.

---

### User Story 3 - Clean, ordered, noise-free flows (Priority: P2)

Every per-change pipeline uses the same ordered stage names as the blog: Prepare → Build → Checks (tests / security / lint or quality) → Infrastructure → Deploy → Verify. A stage that doesn't apply to a project is omitted, or skipped with a reason. History shows real runs, not skip entries.

**Why this priority**: Consistent names are what make the single dashboard and the stage heatmap possible. Skip noise hides the few real runs of manual-only projects.

**Independent Test**: Push a commit to each project, then check its history. Automatic-trigger jobs show one run with contract stage names. Manual-only jobs show no new entry at all.

**Acceptance Scenarios**:

1. **Given** a push to zca-accounting `main`, **When** the webhook arrives, **Then** none of its manual-only jobs records a new history entry.
2. **Given** someone starts zca-accounting `ci` by hand, **When** it runs, **Then** its stages are named per the stage contract and the checks are grouped under Checks.
3. **Given** a branch-indexing event for a zca-accounting pull request, **When** it reaches a manual-only pipeline, **Then** nothing runs. Only manual or upstream-triggered runs execute.
4. **Given** the drift job, **When** pull requests are opened on aws-infrastructure, **Then** no drift runs are created for them.
5. **Given** the deploy jobs no longer discover pull requests, **When** the change is deployed, **Then** their stale PR entries are gone.

---

### User Story 4 - Written catalog of every check, per project (Priority: P3)

Each project has one human-readable catalog listing every check, with:

- its category (blocking / advisory / monitoring)
- what it protects against
- where it runs
- its threshold
- how to waive it, with an expiry

The pipelines read their pass/fail rules from this catalog, so the document and the behaviour cannot drift apart.

**Why this priority**: The rules are useful even before the tooling is perfect. It is the lowest priority because Stories 1–3 deliver the visible fixes.

**Independent Test**: Pick any check that ran on the last build of any in-scope project. Its row in that project's catalog correctly predicts whether a failure of that check turns the run red or yellow.

**Acceptance Scenarios**:

1. **Given** localsetup, aws-infrastructure and zca-accounting, **When** the maintainer looks in each repository, **Then** each has a check catalog in the same format as the blog's.
2. **Given** a check that runs in a pipeline but is missing from its catalog, **When** the pipeline runs, **Then** the run fails loudly and names the uncatalogued check.

---

### Edge Cases

- **Monitoring checks.** A production-data or live-environment check (drift, certificate expiry, vulnerability feed against `main`, local stack health) must never block a change. It belongs to a scheduled monitoring job that alerts.
- **zca-accounting's manual-only rule.** Principle XX stays in force. The spec reduces its noise; it does not automate those pipelines. Infrastructure apply against AWS stays forbidden without an owner amendment. Deploy jobs are restructured only as far as they can be validated without applying.
- **A pull request that can't be merged with its target.** Jenkins records these checkout failures before any stage runs. They are outside the pipeline's control and are reported as such, not counted as check failures.
- **The drift job and the plan job sharing a state lock.** They must never run at the same time.
- **A project with no Build or Deploy stage** (localsetup, the drift job). Those stages are omitted, and the dashboard tolerates their absence.
- **Retired jobs and branches.** They are removed through the documented "Retiring a job" procedure, so dashboards and alerts don't keep reporting stale entries.
- **TraderIntel.** It stays out of scope and must not appear as a failing entry on the new dashboard.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Every per-change pipeline in scope (aws-infrastructure terraform, localsetup ci, zca-accounting ci) MUST classify each check it runs as blocking, advisory or monitoring through a catalog kept in that project's repository.
- **FR-002**: Only a failed *blocking* check may make a run red. An advisory failure makes the run yellow at most. An inconclusive result (outside dependency unreachable) MUST be reported as inconclusive, not failed.
- **FR-003**: A finding that has been reviewed and accepted MUST be recordable as a named exception with a reason. It MUST not affect the run's colour.
- **FR-004**: The "no new issues" comparison MUST use `main` as its reference for pull requests. It MUST NOT be able to hold a project permanently yellow.
- **FR-005**: aws-infrastructure's plan MUST be produced and posted for review even when security scanners report findings. The scanners' verdict is shown alongside the plan and decides the run's colour through the catalog.
- **FR-006**: The drift check MUST make the run red when drift exists, MUST run only for `main`, and MUST continue to notify on drift.
- **FR-007**: Per-change pipelines MUST use the stage contract names Prepare, Build, Checks (sub-stages tests / security / lint or quality), Infrastructure, Deploy and Verify, omitting stages that don't apply.
- **FR-008**: Jobs that must only run by hand MUST NOT create a history entry when a push or pull-request event arrives.
- **FR-009**: zca-accounting's manual-only guard MUST allow only manual or upstream-triggered runs, including when a run is caused by branch indexing.
- **FR-010**: Jobs that act only on `main` (drift, deploys, local refresh) MUST NOT discover pull-request branches. Existing stale entries MUST be removed.
- **FR-011**: A cross-project Grafana dashboard MUST show, for every in-scope job:
  - the latest `main` result
  - per-stage results of the latest run
  - time since last run and since last success
  - a pass-rate trend
  - run duration
- **FR-012**: Alerts MUST fire, by email through the existing alert channel, when:
  - an in-scope project's `main` per-change pipeline is red;
  - a monitoring job is red;
  - a scheduled job has not run within its expected interval (drift 35 days, certificate expiry 8 days).
- **FR-013**: Each in-scope repository MUST have a human-readable check catalog, in the blog's format. A check that runs without a catalog entry MUST fail the run and name the check.
- **FR-014**: The role smoke test MUST offer only role keys that exist. The certificate-expiry job MUST be treated as a monitoring job on the dashboard.
- **FR-015**: Runbooks, READMEs, project instructions and the architecture diagram MUST describe the new layout, catalogs, dashboard and alerts.

### Key Entities

- **Project**: a repository with jobs in Jenkins (aws-infrastructure, zca-accounting, localsetup, ci-maintenance). It has one catalog.
- **Job**: a pipeline for one project. Each job has:
  - a *trigger policy*: automatic, manual-only or scheduled
  - a *branch scope*: `main` + pull requests, or `main` only
- **Stage**: an ordered step with a contract name, as in spec 001.
- **Check**: a unit of verification. Each check has:
  - a category: blocking / advisory / monitoring
  - a threshold
  - a verdict: pass / findings / error / inconclusive / not applicable
- **Exception**: a reviewed, accepted finding, with a reason and an expiry.
- **Scheduled expectation**: the maximum quiet interval for a scheduled job before it counts as stale.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: localsetup `ci` on `main` goes from 1 green run in 8 to green on every run with no new real finding, measured over the first 5 runs after rollout.
- **SC-002**: Zero runs in scope turn red or permanently yellow on a finding already accepted as an exception.
- **SC-003**: 100% of aws-infrastructure pull-request runs that reach planning post their plan, including runs with scanner findings.
- **SC-004**: Drift produces a red result and an alert every time it exists (previously 0%).
- **SC-005**: Skip-only history entries fall from 21 of 23 zca-accounting `main` entries to none for pushes after rollout.
- **SC-006**: From one dashboard, the maintainer can name the failing project and stage within 1 minute for any in-scope failure.
- **SC-007**: A failing `main` or a stale scheduled job produces an alert email within 15 minutes of the dashboard showing it.
- **SC-008**: Every check that runs in an in-scope pipeline has a catalog entry. The target is 100% coverage, enforced by the pipeline.

## Assumptions

- **Scope and operation**
  - Single maintainer.
  - Jenkins and Grafana stay the platform.
  - TraderIntel is excluded.
- **zca-accounting constitution**
  - Principle XX stays in force as written: zca-accounting jobs stay manual-only, and no Terraform apply runs against AWS.
  - Deploy-job changes are limited to noise, branch scope and guard fixes that can be validated without applying.
  - Dev compute is torn down and the production role does not exist, so deploys are not exercised end to end.
- **Where results are read**: the existing Jenkins metrics (latest build result and per-stage result per job) are the dashboard's data source. The dashboard shows current state; the pass-rate trend comes from the stored metric history.
- **Alerting**: alert email reuses the existing Grafana alert channel and recipient.
- **Kept deliberately**
  - The two root-running container findings in localsetup are intentional (the image drives rootless podman) and become documented exceptions.
  - aws-infrastructure's existing inline scanner waivers stay; this spec does not re-review them.
- **The zca-accounting end-to-end suite** starts as advisory because it fails mostly for environmental reasons. Promoting it to blocking is future work.
- **Out of scope**: new container images for zca-accounting (Go, Node or end-to-end toolchains) are a performance improvement, not part of this spec.
