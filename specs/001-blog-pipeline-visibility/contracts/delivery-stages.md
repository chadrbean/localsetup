# Contract: Delivery stages, jobs, and status contexts

The dashboard (Prometheus `stage` label), the catalog (`stage` field) and people all depend on these names. Renaming a stage is a breaking change: the dashboard, the catalog and the docs must be updated together.

## Job layout (seed.groovy)

Folder `blogLosAngeles`. The GitHub status context for each job is `jenkins/<job>`.

| Job | Branches | Purpose |
|---|---|---|
| `delivery` | `main` + `PR-*` | per-change pipeline (below) |
| `security-live` | `main` only (`:main`) | live headers/redirects; after deploy (warn if unreachable) + weekly |
| `seo-live-crawl` | `main` only | weekly live crawl, report-only |
| `data-health` | `main` only | daily `monitoring`-category checks (e.g. surfaced backlog) |

Retired jobs: `deploy`, `smoketests`, `security-gate`, `terraform`.

Build strategies for all four jobs:
- skip the initial indexing build
- ignore commits authored by `jenkins-bot@chadrbean.com`

Folder list view `Overview`, with columns status, name, last success, last failure, last duration:
- *Delivery*: `delivery`
- *Site health*: `security-live`, `seo-live-crawl`, `data-health`

## `delivery` stages (fixed order, exact names)

| # | Stage | Runs when | Skipped reason shown | Blocking content |
|---|---|---|---|---|
| 1 | `Prepare` | always | — | clean the workspace, compute the change set, compute the trigger, check bot commits (backstop) |
| 2 | `Maintain content` | `main`, not a PR, not `DRY_RUN` | "PR build" / "dry run" | archive-past-events and purge-old-posts, each followed by `botPush` in the same stage |
| 3 | `Build` | always | — | one production Hugo build into `site/public` (Hugo failure = blocking) |
| 4 | `Checks` (parallel) | always | — | see the three branches below |
| 4a | `Checks › tests` | always | — | `run_smoketests.py --exclude-category monitoring` with `CI_PREBUILT=1` |
| 4b | `Checks › security` | always | — | secrets, deps, config, policy, built-site (sub-checks via `runCheck`) |
| 4c | `Checks › seo` | always | — | seo_check gate on the same build, plus advisory reports |
| 5 | `Infrastructure` | the change touches `terraform/` or `ci/jenkins/delivery.Jenkinsfile`, or it is a manual run | "no terraform changes" | `tfPlanApply`: PR = plan + comment; main push = apply |
| 6 | `Deploy` | `main`, the change touches `site/` (or cron/manual), not `DRY_RUN`, and stages 3–5 are not FAILURE | "no site changes" / "PR build" / "dry run" / "blocked by <id>" | S3 sync + CloudFront invalidation (`withAwsRole('blog-deploy')`) |
| 7 | `Verify` | after `Deploy` ran | "not deployed" | triggers `security-live` (`wait:false`, `WARN_ON_UNAVAILABLE=true`); records the link |

## Triggers and options

- `cron('H 13 * * *')` on `main` only: daily rebuild. The deploy always runs on cron, which refreshes date-driven content.
- Parameters:
  - `DRY_RUN` (bool)
  - `OVERRIDE_REASON` (string; manual + `main` only)
- Concurrency:
  - `main`: `disableConcurrentBuilds()`. Queued runs are visible in the job page.
  - PRs: `abortPrevious: true`.
- Retention: `buildDiscarder(logRotator(numToKeepStr:'60', daysToKeepStr:'90'))`.
- Failure email: `notifyFailure()` on `main` and cron (existing behaviour). Override runs also email.

## Invariants retained from existing smoketests

- `check_artifact_cleanup`: no `stash` or `archiveArtifacts` of `site/public`. Artifact retention is bounded.
- `check_deploy_push_rebase`: each live archive/purge command is followed by `botPush(` in the same stage. It is retargeted to `delivery.Jenkinsfile`.
- `check_deploy_region`: `AWS_REGION` and the `withAwsRole('blog-deploy', [region:…])` region match the storage provider region. Retargeted.
- `check_hugo_build`: every Jenkinsfile that runs Hugo or smoketests uses `image 'localhost/ci-hugo:<tag>'`.
