# Data Model: Pipeline Visibility & Right-Sized Gating for All Projects

The entities are the same as in spec 001 (`specs/001-blog-pipeline-visibility/data-model.md`): Check, Verdict and Exception. This spec adds the entities below.

## Job policy (seed entry)

| Field | Values | Source |
|---|---|---|
| repo | aws-infrastructure, blogLosAngeles, zca-accounting, localsetup | seed map key |
| name | Jenkinsfile basename | entry before the first `:` |
| branchScope | `main+prs` (default) or `main` (`:main`) | flag |
| trigger | `automatic` (default) or `manual` (`:manual`: no branch-event / indexing builds) | flag |

Rules:

- `:manual` never suppresses manual, upstream (`build job:`) or cron runs.
- `:main` jobs must not have PR items.

## Scheduled expectation

| Job (jenkins_job) | Kind | Max quiet interval | Alert |
|---|---|---|---|
| aws-infrastructure/drift/main | monitoring, monthly cron | 35 days | ci_scheduled_stale |
| ci-maintenance/cert-expiry | monitoring, weekly cron | 8 days | ci_scheduled_stale |

## Per-change job (dashboard "main" row)

| jenkins_job | Catalog |
|---|---|
| aws-infrastructure/terraform/main | aws-infrastructure `ci/checks.yml` |
| localsetup/ci/main | localsetup `ci/checks.yml` |
| zca-accounting/ci/main | zca-accounting `ci/checks.yml` (manual-only) |
| blogLosAngeles/delivery/main | blog `ci/checks.yml` (spec 001) |

## Monitoring job

`aws-infrastructure/drift/main` and `ci-maintenance/cert-expiry` are monitoring jobs; the blog site-health jobs remain on `ci_site_health_failing`. A red monitoring job turns `ci_monitoring_failing` on, and never blocks a change.
