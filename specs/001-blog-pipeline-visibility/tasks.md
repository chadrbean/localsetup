---

description: "Task list for 001 Blog Pipeline Visibility & Right-Sized Gating"
---

# Tasks: Blog Pipeline Visibility & Right-Sized Gating

**Input**: Design documents from `/specs/001-blog-pipeline-visibility/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: The spec does not ask for TDD, so no separate test-first tasks are included. Validation is built into the feature itself: `check_catalog_coverage`, unit tests of changed scripts where scripts already have them, and the quickstart scenarios at each checkpoint.

**Organization**: Tasks are grouped by user story, so each story can be delivered and checked on its own.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1 = right-sized gating, US2 = single pane, US3 = clean ordered flow, US4 = written rules & waivers

## Path Conventions

The work spans two repos. Every path is prefixed with its repo:

- `localsetup/…` is this repo (`/home/chad/git/localsetup`). Work on a feature branch, per `~/.claude/docs/GIT.md`.
- `blogLosAngeles/…` is `/home/chad/git/blogLosAngeles` (a separate repo, with separate PRs).

Jenkins-side facts to rely on:
- Jobs exist only when listed in `localsetup/jenkins/casc/github/seed.groovy`.
- A new seed entry 404s until `POST /configuration-as-code/reload`, and its first build must be triggered by hand.
- Pipelines load the shared library `ci` from `main`, so library changes must merge before pipelines that call them.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Branches, and confirming the Jenkins plugin APIs the design depends on (research D5, D6)

- [X] T001 Create branch `feat/blog-ci-gating` in `localsetup` and branch `feat/ci-check-catalog` in `blogLosAngeles`, validating both names with `git check-ref-format --branch`.
- [X] T002 [P] Confirm that the installed basic-branch-build-strategies (pin at `localsetup/jenkins/plugins.txt:7`) provides the ignore-committer strategy:
  - Inspect `~/.local/share/jenkins/data/plugins/basic-branch-build-strategies/WEB-INF/lib/*.jar` for `IgnoreCommitterStrategy` and its Job DSL/`@Symbol` name.
  - Record the exact DSL syntax, or the fallback (a plugin bump), in `localsetup/specs/001-blog-pipeline-visibility/research.md` under D5.
- [X] T003 [P] Confirm the JCasC key names for pipeline-graph-view 1038 (`showGraphOnJobPage`, `showStageNames`, `showStageDurations`):
  - Find the `@Symbol` on `PipelineGraphViewConfiguration` in `~/.local/share/jenkins/data/plugins/pipeline-graph-view/WEB-INF/lib/*.jar`.
  - Record the YAML path (e.g. `unclassified.pipelineGraphView`) in `localsetup/specs/001-blog-pipeline-visibility/research.md` under D6.
- [X] T004 [P] Record the Prometheus `result_ordinal` → result mapping for the dashboard in `localsetup/specs/001-blog-pipeline-visibility/research.md` under F10:
  - Compare `default_jenkins_builds_last_build_result_ordinal` values from `curl -s http://127.0.0.1:3010/prometheus/` against known build results on disk.
  - Expected: 0 SUCCESS, 1 UNSTABLE, 2 FAILURE, 3 NOT_BUILT, 4 ABORTED. Also confirm the stage-level ordinal meaning of 5.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The catalog, the result contract, and the shared-library steps. All four stories depend on these.

**⚠️ CRITICAL**: No user-story work starts until this phase is complete, and the localsetup part (T008–T010) is merged to `main`.

- [X] T005 Create `blogLosAngeles/ci/checks.yml` following `contracts/check-catalog.md`:
  - Start with `version: 1`.
  - Add one entry per `blogLosAngeles/scripts/smoketests/check_*.py`. The id is the stem minus `check_`, with `_` → `-`.
  - Add one entry per security sub-check: `secrets`, `secret-gate-test`, `deps`, `config-checkov`, `config-zizmor`, `exceptions`, `security-policy`, `built-site`.
  - Add `seo-gate`, `seo-reports`, `hugo-build`, `live-site`, `seo-live-crawl`.
  - Each entry has `id`, `stage`, `category`, `threshold`, `runs_on`, `purpose`, `waiver`, and `command` where the default isn't right.
  - Use the classification from research.md D4 **verbatim**:
    - `surfaced-backlog` is `monitoring`, with stage `data-health`.
    - `pipeline-tests`, `source-shard-coverage`, `unparsable-sources` and `performer-sourced` are `blocking` with `scope: [automation/events-discovery/]`.
    - `gsc-health-tests`, `seo-reports` and non-curated checkov are `advisory`.
  - Rules to respect: "`category: monitoring` MUST have a `stage` that is a site-health job" and "`scope` is allowed only with `category: blocking`".
- [X] T006 [P] Add catalog loading to `blogLosAngeles/scripts/ci/catalog.py`: `load()`, `effective_category(entry, changed_files, trigger)`, and `smoketest_path(id)`.
  - `effective_category` implements the scope rule from data-model.md verbatim: "If set, the check is `blocking` only when the change touches one of these paths. Otherwise it is treated as `advisory`. It is ignored on cron and manual runs, where the check is always treated as `advisory`."
  - Add unit tests in `blogLosAngeles/scripts/ci/test_catalog.py`.
- [X] T007 Add `--category {blocking,advisory,monitoring,change}`, `--exclude-category`, and `--changed-files <file>` to `blogLosAngeles/scripts/run_smoketests.py`, using `scripts/ci/catalog.py`.
  - `change` = blocking + advisory.
  - Exit 1 only when a check whose effective category is blocking fails.
  - Advisory failures print `WARN <id>` and still exit 0.
  - Keep `--only` and `--list` working unchanged.
- [X] T008 [P] Implement `localsetup/jenkins/shared-library/vars/runCheck.groovy` and its help text `runCheck.txt`, exactly per `contracts/check-result-contract.md`:
  - Load `ci/checks.yml` with `readYaml`. Throw an error on an unknown id.
  - Resolve scope with `changedFiles()` and `triggeredBy()`.
  - Run `sh(returnStatus: true)` and map exit codes 0–4 via the category table.
  - Apply the result with `catchError(buildResult:…, stageResult:…)` / `unstable()`.
  - On the first blocking FAILURE, add the badge `Blocked by <id> (<stage>)` and set `currentBuild.description`.
  - Append `| id | category | result | detail |` to `summary.md`.
  - The override branch comes in T020.
- [X] T009 [P] Implement `localsetup/jenkins/shared-library/vars/runCatalogStage.groovy` and `runCatalogStage.txt` per the `runCatalogStage` section of `contracts/check-result-contract.md`:
  - Iterate the catalog entries whose `stage` equals the argument, in order, calling `runCheck` for each.
  - Run every check even after a failure.
  - The stage result is the worst of the mapped results.
- [ ] T010 Add runCheck/runCatalogStage usage to `localsetup/docs/CICD.md`: a new "Check catalog & gating" section covering the exit-code table (0 pass, 1 findings, 2 error, 3 inconclusive, 4 n/a) and the category mapping. Then open the localsetup PR A (T008–T010) and merge it, so pipelines can call the steps.

**Checkpoint**: The catalog exists, `run_smoketests.py --exclude-category monitoring` passes locally on `main`, and the library steps are on `main`.

---

## Phase 3: User Story 1 — Only real defects block a deploy (Priority: P1) 🎯 MVP

**Goal**: Stop the false and unrelated blocks in the existing jobs now, before any restructuring. Data health moves to monitoring, automation tests are scoped, verdicts match exit codes, unreachable externals give "inconclusive", and an emergency override exists.

**Independent Test**: quickstart Scenarios 1, 3 and 7.
- A content-only PR with the backlog over 400 goes green, and the deploy ships.
- checkov warnings give yellow, not red.
- An override run deploys past a failure and is badged.

- [X] T011 [P] [US1] Make the zizmor wrapper in the `config` stage of `blogLosAngeles/ci/jenkins/security-gate.Jenkinsfile` exit 4 ("not applicable") when no workflow files exist or zizmor collected no inputs, instead of `exit 1` on an empty SARIF. Run it through `runCheck('config-zizmor')`.
- [X] T012 [P] [US1] Make osv-scanner exit 3 ("inconclusive") in the `deps` stage of `blogLosAngeles/ci/jenkins/security-gate.Jenkinsfile` when the scanner or advisory DB is unavailable, on every trigger including cron (drop the cron-fails rule). Run it via `runCheck('deps')`.
- [X] T013 [P] [US1] Make `blogLosAngeles/scripts/security/check_live_site.py` exit 3 when `https://otbla.com` is unreachable, and drop `WARN_ON_UNAVAILABLE` handling from `blogLosAngeles/ci/jenkins/security-live.Jenkinsfile` in favour of `runCheck('live-site')`.
- [X] T014 [P] [US1] Change the per-page status label in `blogLosAngeles/scripts/seo_check.py` (≈L508-513) from `FAIL` to `ISSUES` for pages with failed checks. Keep the aggregate `[PASS|FAIL] aggregate score` line and the indexability `FAIL` lines, because those are blocking. Update the wording in `blogLosAngeles/docs/seo-standards.md` to match.
- [X] T015 [US1] Create `blogLosAngeles/ci/jenkins/data-health.Jenkinsfile`:
  - agent `localhost/ci-hugo:1` with `args '-u 0:0'`
  - `buildDiscarder(logRotator(numToKeepStr:'60', daysToKeepStr:'90'))`
  - `cron('H 12 * * *')`
  - a Gate that ends NOT_BUILT unless the branch is main
  - one stage `data-health` calling `runCatalogStage(stage: 'data-health')`
  - `post { always { stepSummary() } failure { notifyFailure() } }`
- [X] T016 [US1] In `blogLosAngeles/ci/jenkins/smoketests.Jenkinsfile`, replace `python3 scripts/run_smoketests.py` with `runCatalogStage(stage: 'checks/tests')`. This interim step keeps today's job working until US2 replaces it, and excludes monitoring checks by construction.
- [X] T017 [US1] In the `smoketests` parallel branch of `blogLosAngeles/ci/jenkins/deploy.Jenkinsfile`, run `python3 scripts/run_smoketests.py --exclude-category monitoring --changed-files changed.txt`, after writing `changed.txt` from `changedFiles()` in the Gate stage. This is interim; US2 replaces the whole file.
- [X] T018 [P] [US1] In `blogLosAngeles/ci/jenkins/agent-validate.groovy`, replace the shell `case` exclusion of `check_surfaced_backlog` with `python3 scripts/run_smoketests.py --exclude-category monitoring`.
- [ ] T019 [US1] Add `data-health:main` to the blogLosAngeles list in `localsetup/jenkins/casc/github/seed.groovy`. Merge it, reload JCasC (`POST /configuration-as-code/reload`), and trigger `blogLosAngeles/data-health/main` manually once.
- [X] T020 [US1] Add the override branch to `localsetup/jenkins/shared-library/vars/runCheck.groovy`, per contract rule 6:
  - When `params.OVERRIDE_REASON` is non-empty, `triggeredBy() == 'manual'` and `env.BRANCH_NAME == 'main'`, turn a blocking FAILURE into UNSTABLE.
  - Add a red `OVERRIDE` badge text `OVERRIDE <id>: <reason> (<user>)`, taking the user from the `UserIdCause`.
  - Append to `env.OVERRIDDEN_CHECKS`.
  - Otherwise, log "OVERRIDE_REASON ignored: manual main runs only".
  - Add `notifyOverride()` to `localsetup/jenkins/shared-library/vars/notifyOverride.groovy`, which emails `ALERT_EMAIL_TO` when `env.OVERRIDDEN_CHECKS` is set.
- [X] T021 [US1] Add `string(name: 'OVERRIDE_REASON', defaultValue: '')` to `blogLosAngeles/ci/jenkins/deploy.Jenkinsfile` parameters, and call `notifyOverride()` in `post { always }` (interim, carried into delivery by T027).
- [ ] T022 [US1] Merge the blogLosAngeles PR for T011–T018 and T021. Then run quickstart Scenarios 1, 3 and 7 against the existing jobs, and record the outcome in the PR description.

**Checkpoint**: The recent failure causes no longer block. MVP delivered: the user can ship again.

---

## Phase 4: User Story 2 — One screen shows where a change is (Priority: P1)

**Goal**: One `delivery` job whose job page (stage table) and run page (graph) show every stage per change, a badge naming the blocking check, a folder overview, and a Grafana site-health/overview dashboard.

**Independent Test**: quickstart Scenario 2. A PR with a broken internal link: from the `delivery` job page, a person names the failing stage and opens the offending href in ≤ 60 s. Scenario 4 as well: PR and main show the same SEO gate.

- [X] T023 [P] [US2] Add the pipeline-graph-view settings (the key confirmed in T003) to `localsetup/jenkins/casc/base/jenkins.yaml`: `showGraphOnJobPage: true`, `showStageNames: true`, `showStageDurations: true`.
- [X] T024 [US2] Create `blogLosAngeles/ci/jenkins/delivery.Jenkinsfile` with the **exact** stage names and order from `contracts/delivery-stages.md`: `Prepare`, `Maintain content`, `Build`, `Checks` (parallel `tests`, `security`, `seo`), `Infrastructure`, `Deploy`, `Verify`.
  - Top-level `agent { label 'podman' }`. Every containerised stage uses `agent { docker { image 'localhost/ci-hugo:1'; reuseNode true; args '-u 0:0' } }`; `Infrastructure` uses `localhost/ci-terraform:1`.
  - `options`: `buildDiscarder(logRotator(numToKeepStr:'60', daysToKeepStr:'90'))`, `timeout(60m)`, `timestamps`.
  - `triggers { cron(env.BRANCH_NAME == 'main' ? 'H 13 * * *' : '') }`.
  - Parameters `DRY_RUN` and `OVERRIDE_REASON`.
  - `environment` keeps `AWS_REGION = 'us-west-1'` at line start (for `check_deploy_region`) plus the S3/CloudFront vars from `deploy.Jenkinsfile`.
- [X] T025 [US2] Implement `Prepare` and `Maintain content` in `blogLosAngeles/ci/jenkins/delivery.Jenkinsfile`:
  - `Prepare`:
    - `git clean -ffdxq`
    - `skipIfBotCommit()` as a backstop
    - write `changed.txt` from `changedFiles()`
    - set `env.SITE_CHANGED`, `env.TF_CHANGED` and `env.CI_TRIGGER` via `pathsChanged([...])` / `triggeredBy()`
    - PRs use `properties([disableConcurrentBuilds(abortPrevious: true)])`, main uses `disableConcurrentBuilds()`
  - `Maintain content` (main && !PR && !DRY_RUN): copy the archive-past-events and purge-old-posts blocks from `blogLosAngeles/ci/jenkins/deploy.Jenkinsfile:83-116` verbatim. Each live script must be followed by `botPush(` in the same stage (`check_deploy_push_rebase`).
- [X] T026 [US2] Implement `Build` and the `Checks` stage in `blogLosAngeles/ci/jenkins/delivery.Jenkinsfile`:
  - `Build`: `dir('site'){ sh 'rm -rf public && HUGO_ENVIRONMENT=production hugo --minify --gc' }` via `runCheck('hugo-build', script: …)`.
  - `Checks`, with three parallel branches:
    - `tests`: `runCatalogStage(stage: 'checks/tests')` with `CI_PREBUILT=1`.
    - `security`: `runCatalogStage(stage: 'checks/security')`, with sub-check commands taken from `blogLosAngeles/ci/jenkins/security-gate.Jenkinsfile`, including the `toolVersion` pin checks.
    - `seo`: `runCheck('seo-gate')` running `seo_check.py --pass-score 85 --format json`, plus `runCheck('seo-reports')` (advisory).
  - `post { always { publishReports(junit:…, checkov:…, gitleaks:…, trivy:…, html:…); stepSummary() } }`.
- [X] T027 [US2] Implement `Infrastructure`, `Deploy` and `Verify` in `blogLosAngeles/ci/jenkins/delivery.Jenkinsfile`:
  - `Infrastructure`: when `TF_CHANGED == 'true'` or the trigger is manual, run `tfPlanApply(dir:'terraform', role:'blog-terraform', region:'us-west-2', applyOnMain: <scm push on main>)`.
  - `Deploy`: when main && !DRY_RUN && (SITE_CHANGED || cron/manual), run the S3 sync / crawler copy / CloudFront invalidation copied from `deploy.Jenkinsfile:170-219`. It must keep `withAwsRole('blog-deploy', [region: 'us-west-1'])`.
  - `Verify`: `build job: 'blogLosAngeles/security-live/main', wait: false`, recording the link with `addSummary`.
  - Each skipped stage sets its skip reason (via `addBadge`/summary text) from the table in `contracts/delivery-stages.md`.
  - `post`: `failure { notifyFailure() }` and `always { notifyOverride() }`.
- [X] T028 [P] [US2] Add `site/public` reuse to `blogLosAngeles/scripts/smoketests/check_hugo_build.py`: when `CI_PREBUILT=1`, verify the pins plus `site/public/index.html`, and skip the rebuild. In `blogLosAngeles/ci/jenkins/security-gate.Jenkinsfile`, the `built-site` logic moves into the catalog `command` for `built-site` so that it reuses the prebuilt site.
- [X] T029 [US2] Update `localsetup/jenkins/casc/github/seed.groovy`:
  - blogLosAngeles list becomes `['delivery', 'security-live:main', 'seo-live-crawl:main', 'data-health:main']`.
  - Add a `listView('blogLosAngeles/Overview')` (or a folder `views {}` block) with sections *Delivery* (`delivery`) and *Site health* (the other three), and columns status, name, last success, last failure, last duration.
  - Keep `notificationContextTrait` so the status is `jenkins/delivery`.
- [X] T030 [P] [US2] Create `localsetup/monitoring/dashboards/ci-blog-delivery.json` (Ops folder, unique uid `ci-blog-delivery`) with these panels:
  1. `delivery/main` last-run stage matrix from `default_jenkins_builds_last_stage_result_ordinal{jenkins_job="blogLosAngeles/delivery/main"}`, using the value mapping from T004 (green, yellow, red, grey).
  2. Open-PR last results from `…last_build_result_ordinal{jenkins_job=~"blogLosAngeles/delivery/PR-.*"}`. Its description includes "Empty is normal".
  3. Site-health status for `security-live|seo-live-crawl|data-health` `/main`, with last-run age.
  4. The 30-day success rate `increase(default_jenkins_builds_success_build_count_total[30d]) / increase(default_jenkins_builds_total_build_count_total[30d])` per job.
  5. Data links to `https://jenkins.chadrbean.com/job/blogLosAngeles/job/<job>/`.
- [X] T031 [P] [US2] Extend `METRIC_RE` in `localsetup/scripts/verify_dashboard.py` (≈L37) to include `default_jenkins_`.
- [X] T032 [P] [US2] Add the Grafana rule `ci_site_health_failing` to `localsetup/monitoring/provisioning/alerting/ci-alerts.yml`, following the style of the existing `jenkins_down` rule in `health-alerts.yml:249-290`:
  - Condition: `max(default_jenkins_builds_last_build_result_ordinal{jenkins_job=~"blogLosAngeles/(security-live|seo-live-crawl|data-health)/main"}) == 2`, `for: 24h`, severity warning.
  - Notification: to the existing email contact point, with a summary naming the job.
- [ ] T033 [US2] Cutover. *Changed during implementation:* the blog PR deletes the four retired Jenkinsfiles in the same change that adds `delivery.Jenkinsfile` (T036/T037 folded in), so the old jobs stop building the moment `delivery` lands and there is never a double-deploy window.
  1. Merge the localsetup PR (T023, T029–T032). Reload JCasC (`POST /configuration-as-code/reload`), then `podman restart monitoring_grafana`. `delivery` now exists and builds the blog PR's own `PR-N` branch.
  2. Check that the blog PR's `delivery` PR build ran every stage as expected (Deploy skipped: "PR checks").
  3. Merge the blogLosAngeles PR (T024–T028 + T036–T039). Watch the first `delivery/main` run; if it doesn't trigger, run a manual build with `DRY_RUN=true`, then without it.
  4. The old jobs `blogLosAngeles/{deploy,smoketests,security-gate,terraform}` no longer find a Jenkinsfile on main. Delete them in the UI after T040's green week (Job DSL's `removedJobAction` is IGNORE).
- [ ] T034 [US2] Run quickstart Scenarios 2 and 4, plus `scripts/verify_dashboard.py --dashboard monitoring/dashboards/ci-blog-delivery.json --from now-24h --alerts`, and record the results in the localsetup PR.

**Checkpoint**: One job page and one dashboard answer "where is my change and what stopped it".

---

## Phase 5: User Story 3 — A clean, ordered delivery flow (Priority: P2)

**Goal**: Each check runs once, bot commits create no builds, the retired pipelines are removed, and invariant checks point at `delivery`.

**Independent Test**: quickstart Scenarios 5 and 6. A content-only merge makes exactly one `hugo --minify --gc` in the log, the bot commits create no builds, a terraform-only PR runs plan and skips Deploy, and NOT_BUILT is ≤ 10% after a week.

- [X] T035 [US3] Add the ignore-committer build strategy (syntax from T002) to the `buildStrategies {}` block in `localsetup/jenkins/casc/github/seed.groovy` (≈L54-56), with ignored author `jenkins-bot@chadrbean.com`, alongside `skipInitialBuildOnFirstBranchIndexing()`. Apply it to every repo, since all repos share `botPush`.
- [X] T036 [P] [US3] Retarget `blogLosAngeles/scripts/smoketests/check_deploy_push_rebase.py` and `check_deploy_region.py` from `ci/jenkins/deploy.Jenkinsfile` to `ci/jenkins/delivery.Jenkinsfile`, and update the "deploy.Jenkinsfile must exist" assertion in `check_artifact_cleanup.py` to `delivery.Jenkinsfile`.
- [X] T037 [US3] Delete `blogLosAngeles/ci/jenkins/deploy.Jenkinsfile`, `smoketests.Jenkinsfile`, `security-gate.Jenkinsfile` and `terraform.Jenkinsfile`. Then grep `blogLosAngeles/` for remaining references (`docs/`, `AGENTS.md`, `CLAUDE.md`, `scripts/`) and repoint them to `delivery.Jenkinsfile`.
- [X] T038 [P] [US3] Remove the `.ci-smoke` worktree handling and any remaining second Hugo build from `blogLosAngeles/scripts/` and `blogLosAngeles/ci/jenkins/agent-validate.groovy`. agent-validate should run one build followed by `run_smoketests.py --exclude-category monitoring` with `CI_PREBUILT=1`.
- [X] T039 [P] [US3] Set `allowEmptyArchive: true` in `blogLosAngeles/ci/jenkins/seo-live-crawl.Jenkinsfile` (≈L56), and make the crawl step go through `runCheck('seo-live-crawl')`, so an empty crawl is reported as n/a rather than a false failure.
- [ ] T040 [US3] Delete the retired jobs in Jenkins after one week of green `delivery/main`, and delete their history directories only after that. Merge the PRs, then run quickstart Scenarios 5 and 6 and the NOT_BUILT count command.

**Checkpoint**: Four jobs, one build per change, no skip churn.

---

## Phase 6: User Story 4 — Written, understandable gating rules (Priority: P3)

**Goal**: A generated, human-readable catalog doc kept in sync by CI, catalog coverage enforced, and waivers that warn before they break.

**Independent Test**: quickstart Scenarios 8 and 9. An uncatalogued `check_dummy.py` fails coverage; waiver expiry within 14 days → WARN, a missing target → WARN "stale", expired → FAIL; any stage in the pane is found in `docs/ci-gates.md`.

- [X] T041 [P] [US4] **Urgent, can ship with US1:** remove the two stale zizmor entries (targets `.github/workflows/deploy.yml:25` and `.github/workflows/security-live.yml:7`) from `blogLosAngeles/.security/exceptions.json`. This defuses the 2026-12-16 failure of every smoketest run.
- [X] T042 [US4] Extend `blogLosAngeles/scripts/security/check_exceptions.py` with:
  - `expiring` WARN (exit 0) when `expires` is ≤ 14 days away
  - `stale` WARN when the file part of `finding` does not exist in the repo
  - the existing FAIL on expired and on > 90 days (`MAX_DAYS`)

  Mirror the behaviour in `blogLosAngeles/scripts/smoketests/check_security_policy.py`, which imports `validate`, and add unit cases to the existing security tests.
- [X] T043 [P] [US4] Create `blogLosAngeles/scripts/ci/render_catalog.py`, which renders `ci/checks.yml` to `blogLosAngeles/docs/ci-gates.md`:
  - A header explaining the three categories, the blocking criteria (spec FR-002), the exit-code table, the override procedure and the waiver procedure.
  - One table per stage/job, with columns id, category, scope, threshold, runs on, purpose, waiver.
  - `--check` exits 1 if the file on disk differs. Generate and commit the file.
- [X] T044 [US4] Create `blogLosAngeles/scripts/smoketests/check_catalog_coverage.py`. It fails when any of the following holds:
  - any `scripts/smoketests/check_*.py` has no entry
  - any `runCheck('…')` / `runCheck(id: '…')` or `runCatalogStage(stage: '…')` in `ci/jenkins/*` references a missing id or stage
  - an entry's default command file doesn't exist
  - a `monitoring` entry has a `delivery` stage
  - `scope` appears on a non-blocking entry
  - `render_catalog.py --check` fails

  Add its own catalog entry (`catalog-coverage`, blocking, stage `checks/tests`).
- [X] T045 [US4] Point `blogLosAngeles/docs/security-gate.md` and `blogLosAngeles/docs/seo-standards.md` at `docs/ci-gates.md` as the authority, remove their duplicated threshold tables (fixing the stale "zizmor audits .github/workflows only while it exists" text), and add "every new check needs a `ci/checks.yml` entry" to `blogLosAngeles/AGENTS.md` and `blogLosAngeles/CLAUDE.md`.
- [ ] T046 [US4] Merge, then run quickstart Scenarios 8 and 9.

**Checkpoint**: The rules are written once, enforced by the step that runs them, and impossible to bypass silently.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T047 [P] Update `localsetup/docs/CICD.md`:
  - The Pipelines table rows for blogLosAngeles become `delivery`, `security-live`, `seo-live-crawl`, `data-health`, with triggers and roles.
  - Add a "Where is my change?" runbook: job page stage table → run graph → badge → dashboard.
  - Add an override runbook.
  - Add troubleshooting for "Blocked by <id>".
- [X] T048 [P] Add the `ci-blog-delivery` dashboard and the `ci_site_health_failing` alert rows to `localsetup/monitoring/README.md` and `localsetup/docs/OBSERVABILITY.md`.
- [X] T049 [P] Update `localsetup/docs/monitoring.drawio` with the Jenkins → Prometheus → Grafana CI path and the blog `delivery` stage flow, including the site-health jobs. Use AWS stencils for the S3/CloudFront targets.
- [X] T050 [P] Update `localsetup/README.md` and `localsetup/CLAUDE.md`:
  - The CI/CD section: the blog uses one `delivery` pipeline plus site-health jobs.
  - Checks must be catalogued and run via `runCheck`/`runCatalogStage`.
  - Exit codes 0–4.
- [X] T051 Run `python3 ci/check_syntax.py` and shellcheck (warning level) in `localsetup/`, and `python3 scripts/run_smoketests.py --exclude-category monitoring` in `blogLosAngeles/`. Fix any findings.
- [ ] T052 Two weeks after cutover, measure SC-001, SC-002, SC-004, SC-005 and SC-007 per the table in `specs/001-blog-pipeline-visibility/quickstart.md`, and append the results to `localsetup/specs/001-blog-pipeline-visibility/quickstart.md` under "Results".

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (T001–T004)**: no dependencies. T002–T004 run in parallel.
- **Foundational (T005–T010)**:
  - T005 → T006 → T007 on the blog side.
  - T008 ∥ T009 → T010 on the localsetup side. PR A must merge before any pipeline calls `runCheck`.
  - This phase blocks every story.
- **US1 (T011–T022)**: after Foundational. The MVP.
- **US2 (T023–T034)**: after Foundational. It reuses US1's script exit-code changes (T011–T014) and the `data-health` seed entry (T019), so do US1 first.
- **US3 (T035–T040)**: after US2's cutover (T033), because it deletes the old Jenkinsfiles.
- **US4 (T041–T046)**:
  - T041 is urgent and independent; ship it with US1.
  - T042–T045 need only Foundational. They can run in parallel with US2 and US3.
  - T044's Jenkinsfile scan is most useful after T024.
- **Polish (T047–T052)**: after the stories they document. T052 runs 2 weeks after T033.

### Story dependency graph

```text
Setup ─► Foundational ─► US1 (MVP) ─► US2 (single pane + cutover) ─► US3 (cleanup)
                     └─► US4 (catalog docs, waivers) ─────────────────────┘
T041 (stale waivers) ── ship with US1 (deadline 2026-12-15)
```

### Within each story

- Scripts before Jenkinsfiles that call them.
- Library (localsetup) merged before pipelines (blogLosAngeles) that use it.
- Seed changes need a JCasC reload plus a manual first build.

## Parallel Examples

### Foundational

```text
T006 scripts/ci/catalog.py        ∥  T008 vars/runCheck.groovy  ∥  T009 vars/runCatalogStage.groovy
```

### User Story 1

```text
T011 zizmor exit 4  ∥  T012 osv exit 3  ∥  T013 live-site exit 3  ∥  T014 seo ISSUES label  ∥  T018 agent-validate  ∥  T041 stale waivers
```

### User Story 2

```text
T023 JCasC graph view  ∥  T028 CI_PREBUILT  ∥  T030 dashboard  ∥  T031 verify_dashboard regex  ∥  T032 alert rule
(T024 → T025 → T026 → T027 are sequential: the same file)
```

### User Story 4

```text
T043 render_catalog.py  ∥  T041 exceptions.json   then   T042 → T044 → T045
```

## Implementation Strategy

### MVP first (US1 + T041)

1. Setup and Foundational: the catalog, `runCheck`, `runCatalogStage`, and the runner flags.
2. US1 on the **existing** jobs: data health moves to monitoring, automation tests are scoped, exit codes are fixed, and the override is added.
3. T041: remove the stale waivers.
4. **Stop and validate** with quickstart Scenarios 1, 3 and 7. Content changes should now ship. This alone addresses the "hard time deploying" pain.

### Incremental delivery

1. US2: the `delivery` consolidation, the single pane and the dashboard. Cut over in one step so that only one job deploys at a time.
2. US3: remove the duplicates, the noise and the retired files.
3. US4: the generated docs, coverage enforcement and waiver warnings.
4. Polish: docs, diagram, and success-criteria measurement.

### PR map

| PR | Repo | Tasks |
|---|---|---|
| A | localsetup | T008–T010, T020 |
| B | blogLosAngeles | T005–T007, T011–T018, T021, T041 |
| B2 | localsetup | T019 |
| C | blogLosAngeles | T024–T028 |
| C2 | localsetup | T023, T029–T032 (the cutover) |
| D | blogLosAngeles | T036–T039, T042–T045 |
| D2 | localsetup | T035, T047–T050 |

## Notes

- [P] = different files and no dependency on incomplete tasks.
- Never stash or archive `site/public`; share the workspace with `reuseNode true` (`check_artifact_cleanup`).
- Deploy stays in us-west-1 to match the S3 provider alias (`check_deploy_region`). All other AWS work stays in us-west-2.
- Reports go only through `publishReports()`. AWS access goes only through `withAwsRole`.
- There are no required checks on the free GitHub plan, so `delivery` on main is the enforcement point.
