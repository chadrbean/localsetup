# Implementation Plan: Blog Pipeline Visibility & Right-Sized Gating

**Branch**: `docs/blog-pipeline-spec` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-blog-pipeline-visibility/spec.md`

## Summary

The blog's six independent Jenkins jobs block deploys on checks unrelated to the change. Most blocks come from a production-data backlog check and the events-automation unit tests; an earlier false failure in the security gate is now fixed. Nothing shows where a change is in the process.

The plan changes four things:

1. **Consolidation.** Replace the four per-change jobs (`deploy`, `smoketests`, `security-gate`, `terraform`) with one ordered `delivery` pipeline:
   - Prepare
   - Maintain content
   - Build (once)
   - Checks (tests, security, seo in parallel)
   - Infrastructure
   - Deploy
   - Verify

   pipeline-graph-view already renders its per-run graph and per-job stage table, and that becomes the single pane.
2. **Classification.** Classify every check in a machine-read catalog (`ci/checks.yml`). A new shared-library step, `runCheck`, maps each check's exit code to a stage result based on its category (blocking, advisory or monitoring). The written rules and the enforced behaviour therefore can't drift apart.
3. **Monitoring separation.** Move data-health checks and live-site checks into `main`-only site-health jobs that alert without blocking. Add a Grafana overview built on the Jenkins metrics Prometheus already scrapes.
4. **Waivers, noise and overrides.**
   - Add waiver expiry warnings and stale-waiver detection. This also defuses the 2026-12-16 failure of every smoketest run.
   - Stop bot commits from creating builds.
   - Add a logged emergency override.

The design rationale is in [research.md](research.md).

## Technical Context

**Language/Version**:
- Jenkins declarative pipeline (Groovy, CPS) on Jenkins LTS 2.555.x
- Python 3.12 for the check scripts (the `ci-hugo:1` image)
- Grafana dashboard JSON and alert-rule YAML

**Primary Dependencies**: all of these are already installed, and no new plugins are needed:
- Jenkins plugins pinned in `jenkins/plugins.txt`: pipeline-graph-view 1038, basic-branch-build-strategies 317, job-dsl, configuration-as-code, pipeline-utility-steps (`readYaml`), badge, warnings-ng, prometheus 860
- Hugo extended 0.160.0
- gitleaks, osv-scanner, checkov and zizmor, pinned in `blogLosAngeles/.security/tool-versions.env`

**Storage**:
- files in git: `ci/checks.yml`, `.security/exceptions.json`, dashboards and alert YAML
- Jenkins build records under `~/.local/share/jenkins/data`
- Prometheus, with 30-day retention

**Testing**:
- blogLosAngeles smoketests (`scripts/run_smoketests.py`), including a new `check_catalog_coverage`, plus unit tests for the new `run_smoketests` flags and the `check_exceptions` warnings
- localsetup `ci/check_syntax.py`, `scripts/verify_dashboard.py --alerts`, and shellcheck at warning level
- the end-to-end scenarios in [quickstart.md](quickstart.md)

**Target Platform**:
- the single Linux host running rootless podman
- Jenkins at `127.0.0.1:3010` / `jenkins.chadrbean.com`
- the monitoring stack on the host network

**Project Type**: CI/CD configuration spanning two repos: `localsetup` (Jenkins platform, shared library, monitoring) and `blogLosAngeles` (pipelines, check scripts, catalog).

**Performance Goals**:
- A content-only merge reaches the live site no slower than today's successful deploys (SC-007). Removing four duplicate Hugo builds and one duplicate smoketest run should make it faster.
- Scenario 2 must be met: the blocking stage identified in ≤ 60 s.

**Constraints**:
- The `site/public` build must not be stashed or archived (`check_artifact_cleanup`). Stages share one workspace via `reuseNode true`.
- JCasC only: UI edits are lost on restart.
- AWS access only through `withAwsRole`.
- Reports only through `publishReports()`.
- Deploy region stays us-west-1 to match the storage provider (`check_deploy_region`). Everything else stays us-west-2.
- The free GitHub plan has no required checks, so `delivery` on `main` is the enforcement point.
- No secrets in git. `.sh` files are shellcheck-clean.

**Scale/Scope**:
- 1 maintainer
- about 3 PRs and 10–20 `main` runs a day (bots included)
- about 30 smoketests and 5 security sub-checks
- 4 Jenkins jobs after the change, down from 6

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled template, so no ratified principles apply.

In its place, the design is checked against the project's binding conventions (`CLAUDE.md` and `docs/CICD.md`):

| Convention | Status |
|---|---|
| Jenkins configured only via JCasC; jobs exist only if in `seed.groovy` | ✅ Seed, views and pipeline-graph-view settings go through JCasC and Job DSL |
| Use the shared library, don't re-implement AWS auth, PR comments, bot pushes or path filters | ✅ `runCheck` joins the library. `withAwsRole`, `tfPlanApply`, `botPush`, `pathsChanged`/`changedFiles` and `prComment` are reused |
| New AWS key needs 4 steps | ✅ N/A: no new roles (`blog-deploy` and `blog-terraform` are reused) |
| Container steps use `args '-u 0:0'`; `JENKINS_HOME` path unchanged | ✅ |
| Reports via `publishReports(...)` in `post { always }` | ✅ `runCheck` does not publish |
| Alerting is Grafana unified alerting only; dashboards git-tracked and checked with `verify_dashboard.py --alerts` | ✅ New dashboard and rule are in `monitoring/`. `verify_dashboard.py`'s `METRIC_RE` is extended to `default_jenkins_` |
| Keep README, CLAUDE.md, docs and `docs/monitoring.drawio` current | ✅ Tasks included (see Documentation below) |
| Region us-west-2 only | ⚠️ Deploy stays us-west-1 because the S3 bucket's provider alias is us-west-1, as enforced by `check_deploy_region`. This is existing state, not a new violation, and is out of scope |

**Result: PASS.** The post-design re-check was also PASS: the Phase 1 artifacts add no plugins, no new AWS roles and no untracked config.

## Project Structure

### Documentation (this feature)

```text
specs/001-blog-pipeline-visibility/
├── plan.md                       # This file
├── research.md                   # Phase 0: findings F1–F12, decisions D1–D11
├── data-model.md                 # Phase 1: Check, Stage, Change, Verdict, Waiver, Override
├── quickstart.md                 # Phase 1: 9 validation scenarios + SC measurement
├── contracts/
│   ├── check-catalog.md          # ci/checks.yml schema and rules
│   ├── check-result-contract.md  # exit codes 0–4 and runCheck mapping/override
│   └── delivery-stages.md        # job layout, stage names/order, triggers, invariants
├── checklists/requirements.md    # spec quality checklist (from /speckit-specify)
└── tasks.md                      # Phase 2 (/speckit-tasks — not created here)
```

### Source Code

```text
localsetup/                                   (this repo)
├── jenkins/
│   ├── casc/github/seed.groovy               # blogLosAngeles: delivery, security-live:main,
│   │                                         #   seo-live-crawl:main, data-health:main;
│   │                                         #   ignore-committer build strategy; folder listView
│   ├── casc/base/jenkins.yaml                # (no change: pipeline-graph-view has no JCasC
│   │                                         #   settings; stage graph is on by default)
│   └── shared-library/vars/
│       ├── runCheck.groovy                   # NEW: catalog lookup, exit-code→result, badge, override
│       └── runCheck.txt                      # NEW: step help
├── monitoring/
│   ├── dashboards/ci-blog-delivery.json      # NEW: stage matrix, PRs, site health, success trend
│   └── provisioning/alerting/ci-alerts.yml   # NEW: ci_site_health_failing (24h backstop)
├── scripts/verify_dashboard.py               # METRIC_RE += default_jenkins_
├── docs/CICD.md                              # blog rows → 4 jobs; runCheck; catalog; override runbook
├── docs/OBSERVABILITY.md / monitoring/README.md   # dashboard + alert rows
├── docs/monitoring.drawio                    # Jenkins→Prometheus→Grafana CI panel; delivery flow
└── README.md, CLAUDE.md                      # job list and conventions

blogLosAngeles/                               (separate repo, separate PRs)
├── ci/
│   ├── checks.yml                            # NEW: catalog (source of truth)
│   └── jenkins/
│       ├── delivery.Jenkinsfile              # NEW: 7 stages (contracts/delivery-stages.md)
│       ├── data-health.Jenkinsfile           # NEW: daily monitoring-category checks
│       ├── security-live.Jenkinsfile         # exit 3 on unreachable; runCheck
│       ├── seo-live-crawl.Jenkinsfile        # allowEmptyArchive true; runCheck
│       ├── agent-validate.groovy             # uses --exclude-category monitoring
│       └── {deploy,smoketests,security-gate,terraform}.Jenkinsfile   # DELETED after cutover
├── scripts/
│   ├── run_smoketests.py                     # --category/--exclude-category from catalog
│   ├── seo_check.py                          # per-page label FAIL→ISSUES
│   ├── ci/render_catalog.py                  # NEW: checks.yml → docs/ci-gates.md (--check)
│   ├── security/check_exceptions.py          # 14-day WARN, stale-target WARN
│   ├── security/check_live_site.py           # exit 3 when unreachable
│   └── smoketests/
│       ├── check_catalog_coverage.py         # NEW
│       ├── check_hugo_build.py               # honour CI_PREBUILT=1
│       └── check_{artifact_cleanup,deploy_push_rebase,deploy_region}.py  # retarget → delivery.Jenkinsfile
├── .security/exceptions.json                 # remove 2 stale zizmor entries
└── docs/ci-gates.md (generated), docs/security-gate.md, docs/seo-standards.md, AGENTS.md, CLAUDE.md
```

**Structure Decision**: The work spans two repos. Platform pieces go in `localsetup/jenkins` and `monitoring`: the seed, JCasC, the shared-library step, the dashboard and the alert. Pipeline definitions, check scripts and the catalog go in `blogLosAngeles`, because the checks and their rules belong to the app repo.

### Delivery sequence

The order below makes sure only one job deploys at any moment:

1. **localsetup PR A** (safe to merge first, no behaviour change):
   - `runCheck` step
   - pipeline-graph-view JCasC settings
   - `verify_dashboard` regex
   - the dashboard (the PR/site-health panels are empty at first; mark them "Empty is normal")
2. **blogLosAngeles PR B**:
   - catalog, `run_smoketests` flags, `render_catalog`, `check_catalog_coverage`
   - exit-code changes and waiver warnings, with the stale waivers removed
   - `check_hugo_build` `CI_PREBUILT`, the SEO label change
   - `delivery.Jenkinsfile` and `data-health.Jenkinsfile`
   - retargeted parsing checks

   The old Jenkinsfiles stay in this PR and keep working.
3. **localsetup PR C (the cutover)**:
   - seed switch to the 4 jobs, plus the bot-ignore strategy, the folder view and the alert rule
   - JCasC reload, then manual first builds of `delivery/main` and the three site-health jobs
   - disable the 4 retired jobs in Jenkins (Job DSL leaves them in place because `removedJobAction` is IGNORE)
4. **blogLosAngeles PR D** (cleanup): delete the 4 retired Jenkinsfiles, and update docs, AGENTS.md and CLAUDE.md.
5. Run quickstart scenarios 1–9, and schedule the 2-week success-criteria measurement.

Pipelines take the shared library from `main`, so PR A must merge before PR B's `delivery` can run. PR B's own PR build then exercises `delivery` against the real library.

## Complexity Tracking

There are no constitution violations. One deliberate trade-off is recorded here:

| Choice | Why needed | Simpler alternative rejected because |
|---|---|---|
| A catalog read at runtime by `runCheck`, rather than a docs table | Makes the documented category the enforced category (SC-006, US4-2) | A markdown table already drifts: today's docs say zizmor runs "while workflows exist", yet the gate failed when they didn't |
| Path-scoped blocking for automation tests (`scope:`) | Stops 7 of the 10 recent deploy blocks while keeping automation PRs gated | Always-blocking repeats the problem; always-advisory removes the gate for automation changes |
