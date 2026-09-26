# Tasks: Pipeline Visibility & Right-Sized Gating for All Projects

**Input**: design documents in `specs/002-all-project-pipelines/`
**Tests**: no test-first tasks were requested. Validation is the static checks plus real builds in quickstart.md.

Repos:

| Name | Path |
|---|---|
| localsetup (LS) | `/home/chad/git/localsetup` (this worktree) |
| aws-infrastructure (AI) | `/home/chad/git/aws-infrastructure` |
| zca-accounting (ZA) | `/home/chad/git/zca-accounting` |

## Phase 1: Setup

- [x] T001 Create worktrees and branches `feat/ci-catalog` in AI and ZA from origin/main. Keep LS on `docs/pipeline-visibility-all`.

## Phase 2: Foundational (the shared library and seed that every story needs)

- [x] T002 Add `jenkins/shared-library/vars/manualOnly.groovy`: an allow-list guard (default `['manual','upstream']`) that sets NOT_BUILT with a reason and returns a boolean.
- [x] T003 Change `jenkins/shared-library/vars/tfPlanApply.groovy`:
  - pre-check scanners use returnStatus and never throw before the plan;
  - the PR comment includes `env.CHECK_RESULTS`;
  - no apply when `currentBuild.currentResult == 'FAILURE'`.
- [x] T004 [P] Change `jenkins/shared-library/vars/publishReports.groovy`: on a PR, the reference job is the target branch's sibling job.
- [x] T005 [P] Make `checkReport.groovy` and `runCheck.groovy` repo-neutral: the doc link (`docs/ci-gates.md`) is fine for all repos, and the error message for a missing command no longer assumes blog smoketests.
- [x] T006 Add `:main` / `:manual` flag parsing to `jenkins/casc/github/seed.groovy`, per contracts/seed-job-flags.md. `:manual` gets an unsatisfiable `buildAllBranches { buildRegularBranches(); buildChangeRequests{} }`.

## Phase 3: User Story 1: only real defects turn a project red (P1)

- [x] T007 [US1] LS `ci/checks.yml`:
  - gitleaks, shellcheck and check-syntax are blocking;
  - trivy-config is advisory.
- [x] T008 [US1] LS `.trivyignore.yaml`: DS-0002 and DS-0026, path-scoped to `jenkins/images/ci-podman/Containerfile`, each with a statement.
- [x] T009 [US1] LS `ci/jenkins/ci.Jenkinsfile`:
  - Prepare → Checks » security / lint through runCheck;
  - drop failOnNewIssues;
  - `post { always { publishReports; checkReport; stepSummary } }`.
- [x] T010 [P] [US1] AI `ci/checks.yml`:
  - tf-fmt, tf-validate, checkov and trivy-config are blocking;
  - tf-drift is monitoring.
- [x] T011 [US1] AI `ci/jenkins/terraform.Jenkinsfile`: Prepare (init) → Checks » lint / security → Infrastructure (tfPlanApply without preChecks); drop the NOT_BUILT path gate.
- [x] T012 [P] [US1] ZA `ci/checks.yml`: the categories from contracts/project-stages.md.
- [x] T013 [US1] ZA `ci/jenkins/ci.Jenkinsfile`: Prepare (shared manualOnly) → Checks parallel tests / security / quality / e2e, every command through runCheck; checkReport and stepSummary.

## Phase 4: User Story 2: one screen for every project (P1)

- [x] T014 [US2] LS `monitoring/dashboards/ci-overview.json`:
  - latest main result per job
  - stage table
  - time since last run and last success
  - pass rate
  - duration
  - scheduled staleness
- [x] T015 [US2] LS `monitoring/provisioning/alerting/ci-alerts.yml`: add `ci_main_failing`, `ci_monitoring_failing` and `ci_scheduled_stale`.
- [x] T016 [US2] AI `ci/jenkins/drift.Jenkinsfile`: `runCheck(id: 'tf-drift')` with plan exit 2 → 1 and 1 → 2. Keep the email and issue; the stage is `Verify`.

## Phase 5: User Story 3: clean, noise-free flows (P2)

- [x] T017 [US3] Seed entries:
  - AI `drift:main:manual`;
  - ZA `ci:manual`, `deploy-dev:main:manual`, `deploy-prod:main:manual`, `local-refresh:main:manual`;
  - blog site-health jobs `:main:manual`.
- [x] T018 [US3] ZA `deploy-dev.Jenkinsfile` and `deploy-prod.Jenkinsfile`: replace the local `manualOnly()` with the shared step.
- [x] T019 [US3] Seed `aws-role-smoke`: drop the `zca-prod` choice (the role does not exist).

## Phase 6: User Story 4: written catalogs (P3)

- [x] T020 [P] [US4] LS `docs/ci-gates.md`
- [x] T021 [P] [US4] AI `docs/ci-gates.md`
- [x] T022 [P] [US4] ZA `docs/ci-gates.md` + `docs/rules/ci-cd.md` (the new stage layout; Principle XX unchanged)

## Phase 7: Polish, deploy and validation

- [x] T023 Update LS docs:
  - `docs/CICD.md`: seed flags, per-project layout, manualOnly, tfPlanApply behaviour;
  - `docs/SECURITY-MONITORING.md`, or the monitoring README: the new dashboard and alerts;
  - `README.md`;
  - `CLAUDE.md`;
  - `docs/monitoring.drawio`: add the ci-overview dashboard.
- [x] T024 [P] Update the AI `README.md` pipeline section; remove the stale Actions workflows only if Jenkins now fully covers them.
  Status: the README CI table shipped in AI #8. The owner chose to disable, not delete: AI #10 renamed `terraform.yml` and `drift-detection.yml` to `*.yml.disable` (the blog convention). Jenkins terraform main #10 passed on the merge.
- [x] T025 Run the static checks: check_syntax, shellcheck, groovyc on every changed Groovy file, and verify_dashboard.
- [x] T026 Open the PRs and merge them: LS first, then AI and ZA.
  Status 2026-09-26: LS #29/#30, AI #8/#9 and ZA #98 are merged (ZA #98 by the owner, `d863ed6`).
  Correction: an earlier note said zca main #9 failed the same go-test checks. That build ran a stale commit (`c068336`), not main's head. After origin/main was merged into #98, the go-test failure was gone.
- [x] T027 Pull LS main into the mounted checkout; restart Jenkins; confirm the seed applied (job configs show the new strategies); archive the stale PR items of the main-only jobs.
  Five PR items, 9.9 MB in total, were moved to `~/.local/share/jenkins/archive/2026-09-26-main-only-pr-items/`: zca deploy-dev and deploy-prod PR-94/PR-97, and aws drift PR-5. After the restart each of those jobs lists only `main`, with 0 SEVERE log lines.
- [x] T028 Restart Grafana; run verify_dashboard live; confirm the alert rules loaded.
- [x] T029 Run quickstart scenarios 1–7 and fix until each gives its expected result.
  - Passed: 1 (localsetup/ci main #9/#10, push-triggered), 2 (terraform/main #9, 0 changes), 3 (drift/main #4), 6 (verify_dashboard ci-overview: 39 pass, 1 warn for cert-expiry with no data yet), 7.
  - Scenario 4: zca main #12 (core tier, 4 checks) and main #13 (RUN_QUALITY, all 18 checks incl. web-e2e and go-test-integration) are both SUCCESS.
  - Scenario 5: branch indexing logged "No automatic build triggered" for zca main and PR-98, so manual-only holds.
  - The e2e checks in PR-98 #2 errored because main #9's e2e stack held the offset ports. Fix: the e2e port check now waits up to 30 min for the ports to free up before failing.
  - PR-98 #3 hit JENKINS-37121 (a workspace lock collision) and was aborted when the PR merged mid-build. It did not recur on main #13.
  - A Jenkins restart at 13:41 (another deploy) emptied the Prometheus job metrics until the plugin's first 60 s collection. Re-check the dashboard after that window, not straight after a restart.
- [x] T030 Update the memory file and write the final report.

## Dependencies

- T002–T006 come before every pipeline task, because the pipelines call `manualOnly` and the new tfPlanApply.
- T026 (merge LS) comes before any AI or ZA build, because the shared library loads from GitHub main.
- US1–US4 are independent once Phase 2 is merged.

## Parallel opportunities

- The three catalogs (T007, T010, T012) and the three docs (T020–T022) can be written in parallel.
- AI and ZA work proceed in separate worktrees.

## MVP

Phase 2 plus US1 on localsetup (T007–T009). That alone turns the permanently yellow job green.
