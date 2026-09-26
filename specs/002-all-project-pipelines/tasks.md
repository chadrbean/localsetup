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
- [ ] T010 [P] [US1] AI `ci/checks.yml`:
  - tf-fmt, tf-validate, checkov and trivy-config are blocking;
  - tf-drift is monitoring.
- [ ] T011 [US1] AI `ci/jenkins/terraform.Jenkinsfile`: Prepare (init) → Checks » lint / security → Infrastructure (tfPlanApply without preChecks); drop the NOT_BUILT path gate.
- [ ] T012 [P] [US1] ZA `ci/checks.yml`: the categories from contracts/project-stages.md.
- [ ] T013 [US1] ZA `ci/jenkins/ci.Jenkinsfile`: Prepare (shared manualOnly) → Checks parallel tests / security / quality / e2e, every command through runCheck; checkReport and stepSummary.

## Phase 4: User Story 2: one screen for every project (P1)

- [x] T014 [US2] LS `monitoring/dashboards/ci-overview.json`:
  - latest main result per job
  - stage table
  - time since last run and last success
  - pass rate
  - duration
  - scheduled staleness
- [x] T015 [US2] LS `monitoring/provisioning/alerting/ci-alerts.yml`: add `ci_main_failing`, `ci_monitoring_failing` and `ci_scheduled_stale`.
- [ ] T016 [US2] AI `ci/jenkins/drift.Jenkinsfile`: `runCheck(id: 'tf-drift')` with plan exit 2 → 1 and 1 → 2. Keep the email and issue; the stage is `Verify`.

## Phase 5: User Story 3: clean, noise-free flows (P2)

- [x] T017 [US3] Seed entries:
  - AI `drift:main:manual`;
  - ZA `ci:manual`, `deploy-dev:main:manual`, `deploy-prod:main:manual`, `local-refresh:main:manual`;
  - blog site-health jobs `:main:manual`.
- [ ] T018 [US3] ZA `deploy-dev.Jenkinsfile` and `deploy-prod.Jenkinsfile`: replace the local `manualOnly()` with the shared step.
- [x] T019 [US3] Seed `aws-role-smoke`: drop the `zca-prod` choice (the role does not exist).

## Phase 6: User Story 4: written catalogs (P3)

- [x] T020 [P] [US4] LS `docs/ci-gates.md`
- [ ] T021 [P] [US4] AI `docs/ci-gates.md`
- [ ] T022 [P] [US4] ZA `docs/ci-gates.md` + `docs/rules/ci-cd.md` (the new stage layout; Principle XX unchanged)

## Phase 7: Polish, deploy and validation

- [x] T023 Update LS docs:
  - `docs/CICD.md`: seed flags, per-project layout, manualOnly, tfPlanApply behaviour;
  - `docs/SECURITY-MONITORING.md`, or the monitoring README: the new dashboard and alerts;
  - `README.md`;
  - `CLAUDE.md`;
  - `docs/monitoring.drawio`: add the ci-overview dashboard.
- [ ] T024 [P] Update the AI `README.md` pipeline section; remove the stale Actions workflows only if Jenkins now fully covers them.
- [ ] T025 Run the static checks: check_syntax, shellcheck, groovyc on every changed Groovy file, and verify_dashboard.
- [ ] T026 Open the PRs and merge them: LS first, then AI and ZA.
- [ ] T027 Pull LS main into the mounted checkout; restart Jenkins; confirm the seed applied (job configs show the new strategies); archive the stale PR items of the main-only jobs.
- [ ] T028 Restart Grafana; run verify_dashboard live; confirm the alert rules loaded.
- [ ] T029 Run quickstart scenarios 1–7 and fix until each gives its expected result.
- [ ] T030 Update the memory file and write the final report.

## Dependencies

- T002–T006 come before every pipeline task, because the pipelines call `manualOnly` and the new tfPlanApply.
- T026 (merge LS) comes before any AI or ZA build, because the shared library loads from GitHub main.
- US1–US4 are independent once Phase 2 is merged.

## Parallel opportunities

- The three catalogs (T007, T010, T012) and the three docs (T020–T022) can be written in parallel.
- AI and ZA work proceed in separate worktrees.

## MVP

Phase 2 plus US1 on localsetup (T007–T009). That alone turns the permanently yellow job green.
