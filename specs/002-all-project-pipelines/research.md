# Research: Pipeline Visibility & Right-Sized Gating for All Projects

Evidence was collected on 2026-09-26 from the Jenkins data on disk, the Jenkinsfiles on each repo's `origin/main`, and Prometheus. Each decision below lists what was chosen, why, and the alternatives.

## R1. Reuse spec 001's catalog machinery unchanged

- **Decision**: every repo gets a `ci/checks.yml` in the blog's format: `id`, `stage`, `category`, `threshold`, `runs_on`, `purpose`, `command`, `waiver`. Checks run through the shared-library steps `runCheck`, `runCatalogStage` and `checkReport`, which are already generic.
- **Rationale**: `runCheck` already maps exit codes to results by category. It already fails the run for an uncatalogued id, which satisfies FR-013 with no new code. Contract: `specs/001-blog-pipeline-visibility/contracts/check-result-contract.md`.
- **Alternatives**:
  - A per-repo check runner: rejected; it duplicates code.
  - A generated `docs/ci-gates.md` per repo, as the blog does: rejected for now. The YAML is commented and human-readable, and each repo's `docs/ci-gates.md` explains the rules and links to it.

## R2. Silence manual-only jobs at the source (FR-008)

- **Decision**: seed entries take flags: `name:main` (discover only main) and `name:manual` (no automatic builds). They combine, e.g. `deploy-dev:main:manual`.
  - A `:manual` job's branch source gets `buildAllBranches { buildRegularBranches(); buildChangeRequests{} }`. No head is both a branch and a PR, so branch events and indexing never start a build, and no NOT_BUILT entry is written.
  - Manual "Build", `build job:` (upstream) and `cron` triggers are unaffected, because branch build strategies apply only to automatic SCM builds.
- **Applied to**:
  - all four zca-accounting jobs (Principle XX)
  - aws-infrastructure `drift` (cron/manual only; also avoids the state-lock race on push)
  - the blog's three site-health jobs (deploy, cron or manual only)
- **Alternatives**:
  - `suppressAutomaticTriggering` branch property: rejected. It requires switching the branch source to a per-branch strategy block, and it interacts with the plugin's NoTrigger migration.
  - `buildNamedBranches` with an exact filter that matches no branch: rejected. The exact-name filter has no `@Symbol`, so its Job DSL name couldn't be verified offline, and a wrong name fails the seed at boot. The AND form uses only symbols read from the plugin jar.

## R3. Shared `manualOnly()` guard (FR-009)

- **Decision**: add a shared-library step `manualOnly(allow: ['manual', 'upstream'])`. It returns `true` only when `triggeredBy()` is in the allow-list. Otherwise it marks the run NOT_BUILT with a Principle XX description.
- **Rationale**: all three zca-accounting Jenkinsfiles carry a local copy that refuses only `'scm'`, which lets `'indexing'` through (PR-97 #2, #7, #11). An allow-list fails safe. With R2 in place the guard is a backstop.
- **Alternatives**: patch the three copies in place. Rejected; the copies would drift apart again.

## R4. aws-infrastructure: checks as catalog stages, plan always posted (FR-005, FR-006)

- **Decision**:
  - `terraform.Jenkinsfile` becomes Prepare → Checks (`lint`: tf-fmt, tf-validate; `security`: checkov, trivy-config) → Infrastructure (`tfPlanApply`).
  - `tfPlanApply` changes:
    - (a) scanner pre-checks no longer throw before the plan;
    - (b) the PR comment includes `env.CHECK_RESULTS` when present;
    - (c) apply is skipped when the run is already FAILURE.
  - The NOT_BUILT path filter is dropped: a plan of an unchanged tree is a cheap no-op and a useful drift signal.
  - `drift.Jenkinsfile` runs `runCheck(id: 'tf-drift')` (monitoring). Plan exit 2 is mapped to 1, so drift turns the run red and still emails and opens an issue.
- **Rationale**: the plan comment is what a reviewer needs, and a scanner finding must not hide it. Drift that stays green is invisible.
- **Alternatives**: keep scanner checks inside `tfPlanApply`. Rejected, because then they can't appear as catalog stages on the dashboard heatmap.

## R5. localsetup `ci`: stop the permanent yellow (FR-003, FR-004)

- **Decision**:
  - Stages: Prepare → Checks (`security`: gitleaks [blocking], trivy-config [advisory]; `lint`: shellcheck [blocking], check-syntax [blocking]).
  - The two intentional ci-podman Containerfile findings (DS-0002 runs as root, DS-0026 no HEALTHCHECK) go in `.trivyignore.yaml` with a path scope and a statement.
  - `publishReports` no longer gets `failOnNewIssues` here. For PRs it discovers its reference build from the target branch's job.
- **Rationale**: the catalog decides the colour. The warnings-ng "new issues" gate was the sticky source of UNSTABLE, because its reference had to have passed that same gate.
- **Alternatives**: global `.trivyignore` IDs. Rejected; they would hide DS-0002 in every future Containerfile.

## R6. zca-accounting `ci`: contract stages, catalog, Principle XX kept (FR-001/2/7/9)

- **Decision**:
  - The job keeps its name `ci` and stays manual-only.
  - Stages: Prepare (allow-list gate) → Checks (parallel `tests`, `security`, `quality`, `e2e`).
  - Every command runs through `runCheck` from `ci/checks.yml`.
  - Categories:
    - **blocking**: go-vet, go-test (+ constitution floors), web-typecheck, web-test (+ money floor), tf-fmt-validate, region-policy, shellcheck
    - **advisory**: go-lint, gosec, govulncheck, pnpm-audit, eslint, prettier, docs-currency, diagram-currency, commitlint, web-e2e, go-test-integration
  - Quality, security and e2e run only with `RUN_QUALITY=true`, as today.
  - The deploy jobs switch to the shared `manualOnly()`; nothing else changes.
- **Rationale**: the constitution's coverage floors are real defects. Lint deprecations, process currency and a 48-minute environment-flaky suite are not. Principle XX is NON-NEGOTIABLE, and apply is forbidden, so deploys can't be exercised.
- **Alternatives**:
  - Rename the job to `delivery`: rejected. zca-accounting has no automatic deploy, so the job is a check run, and a rename churns history and docs.
  - Fold deploy-dev into ci: rejected; forbidden apply.

## R7. Cross-project Grafana dashboard and alerts (FR-011, FR-012)

- **Decision**: `monitoring/dashboards/ci-overview.json`, from the existing prometheus-plugin series.
  - `last_build_result_ordinal`: latest result per job on main.
  - `last_stage_result_ordinal`: stage table.
  - `last_build_start_time_milliseconds`: time since last run.
  - `max_over_time` of the start time when the result is 0: time since last success, over 30 days.
  - `success_build_count_total` / `total_build_count_total`: pass rate.
  - `last_build_duration_milliseconds`: duration.
  - Alerts in `ci-alerts.yml`:
    - `ci_main_failing`: per-change jobs on main at ordinal 2 for 10 minutes.
    - `ci_monitoring_failing`: drift or cert-expiry red.
    - `ci_scheduled_stale`: drift more than 35 days since last start, cert-expiry more than 8 days.
- **Rationale**: no new exporter is needed. The `jenkins_job` label carries repo/job/branch.
- **Alternatives**: extend the blog dashboard. Rejected; it is built around the blog's stage contract.

## R8. Stale PR branches in main-only jobs (FR-010)

- **Decision**: after the seed reload, archive `zca-accounting/{deploy-dev,deploy-prod}/branches/PR-*`, using the "Retiring a job" runbook step (move the folder out of JENKINS_HOME, then restart). The orphaned-item strategy would otherwise keep them for 14 days.
- **Alternatives**: change `daysToKeep` for main-only jobs. Rejected; it also changes how quickly deleted branches disappear.
