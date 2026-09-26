# Implementation Plan: Pipeline Visibility & Right-Sized Gating for All Projects

**Branch**: `docs/pipeline-visibility-all` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

## Summary

This applies spec 001's model to aws-infrastructure, zca-accounting, localsetup and ci-maintenance:

- a check catalog per repo, where the category decides the run's colour
- stage-contract names
- no skip noise
- one cross-project Grafana dashboard with alerts

The work is mostly configuration:

- the Jenkins seed
- five shared-library steps: new `manualOnly`, plus changes to `tfPlanApply`, `publishReports`, `checkReport` and `runCheck`
- six Jenkinsfiles
- three catalogs
- one dashboard and three alert rules

## Technical Context

**Language/Version**: Jenkins declarative pipelines + Groovy shared library (Jenkins LTS 2.568.3), Job DSL seed, YAML catalogs, Grafana dashboard JSON / alert provisioning YAML, Bash.
**Primary Dependencies**:
- Jenkins plugins, all already installed:
  - job-dsl
  - basic-branch-build-strategies 317
  - pipeline-utility-steps (`readYaml`)
  - warnings-ng
  - forensics (`discoverReferenceBuild`)
  - prometheus
- Grafana unified alerting.
- Prometheus.
**Storage**: N/A. Build history lives in JENKINS_HOME; metrics live in Prometheus.
**Testing**:
- `python3 ci/check_syntax.py` (YAML/JSON)
- shellcheck
- Groovy compile check (`groovyc.sh`)
- `scripts/verify_dashboard.py --alerts`
- real builds on each job after reload (quickstart.md)
**Target Platform**: this host: Jenkins in rootless podman, `jenkins.chadrbean.com`.
**Project Type**: CI/CD configuration across 4 repos.
**Performance Goals**: a failure is visible on the dashboard within 1 scrape plus 1 minute, and alerts within 15 minutes.
**Constraints**:
- Principle XX (zca-accounting): manual-only, no apply.
- AWS only via `withAwsRole`.
- JCasC only.
- Never make a live or production-data check blocking.
**Scale/Scope**: 4 repos, 11 jobs, about 30 checks.

## Constitution Check

The localsetup constitution is an unfilled template, so it has no gates. The binding project rules come from `CLAUDE.md`:

| Rule | Status |
|---|---|
| JCasC/seed only, no UI edits | ✅ all Jenkins changes are in `jenkins/casc/github/seed.groovy` + shared library |
| AWS only via `withAwsRole`, us-west-2 | ✅ no new roles or keys |
| Reports only via `publishReports` | ✅ |
| Monitoring checks never blocking | ✅ drift / cert-expiry = monitoring |
| Docs + diagram current | ✅ tasks T040–T044 |
| zca-accounting Principle XX (NON-NEGOTIABLE) | ✅ kept: manual-only, no apply, deploys only get the shared guard |

## Project Structure

### Documentation (this feature)

```text
specs/002-all-project-pipelines/
├── spec.md  plan.md  research.md  data-model.md  quickstart.md  tasks.md
├── checklists/requirements.md
└── contracts/
    ├── seed-job-flags.md        # :main / :manual semantics
    └── project-stages.md        # stage names + check ids per project
```

### Source Code (repository root)

```text
localsetup/
├── jenkins/casc/github/seed.groovy               # flags, drift:main:manual, zca :manual, smoke keys
├── jenkins/shared-library/vars/
│   ├── manualOnly.groovy                         # NEW allow-list guard
│   ├── tfPlanApply.groovy                        # scanners don't throw; CHECK_RESULTS in PR comment; no apply after FAILURE
│   ├── publishReports.groovy                     # PR reference = target branch job
│   ├── checkReport.groovy                        # catalog doc link per repo
│   └── runCheck.groovy                           # generic default command message
├── ci/checks.yml  ci/jenkins/ci.Jenkinsfile  .trivyignore.yaml  docs/ci-gates.md
├── monitoring/dashboards/ci-overview.json
├── monitoring/provisioning/alerting/ci-alerts.yml
└── docs/CICD.md  docs/OBSERVABILITY.md?  docs/monitoring.drawio  README.md  CLAUDE.md
aws-infrastructure/
├── ci/checks.yml  docs/ci-gates.md
└── ci/jenkins/{terraform,drift}.Jenkinsfile
zca-accounting/
├── ci/checks.yml  docs/ci-gates.md (+ docs/rules/ci-cd.md update)
└── ci/jenkins/{ci,deploy-dev,deploy-prod}.Jenkinsfile
```

**Structure Decision**:
- Each repo owns its catalog and Jenkinsfiles.
- localsetup owns the seed, the shared library, the dashboard and the alerts.
- PR order: localsetup shared library first (the pipelines call the new steps), then the per-repo PRs. The seed reload and Jenkins restart come last.

## Complexity Tracking

None. There are no new services, images or exporters.
