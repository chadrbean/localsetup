# Research: Blog Pipeline Visibility & Right-Sized Gating

**Phase 0 output for** [plan.md](plan.md) · **Date**: 2026-09-25

All findings come from read-only inspection of `blogLosAngeles/ci/jenkins/*`, `scripts/`, `.security/`, and `localsetup/jenkins/`, plus on-disk Jenkins build records (`~/.local/share/jenkins/data`) and the unauthenticated `/prometheus/` endpoint. No credentials were used.

## Findings that correct or refine the spec baseline

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| F1 | The security-gate "Blocking: 0 but failed" was the zizmor step. `[ -s zizmor.sarif ] \|\| exit 1` fired because every workflow had been renamed `*.yml.disable`, so zizmor audited nothing. | `security-gate.Jenkinsfile:115`, build logs main #26/#28, PR-221/223 | Already fixed by 19862f1 (main #38 green). FR-003 is still needed as a general rule: "no input" must be *not applicable*, never *failed*. |
| F2 | `check_surfaced_backlog` reads the committed `automation/events-discovery/state.json`, which bots commit several times a day, and compares it with `date.today()`. | `check_surfaced_backlog.py:40` | The result depends on the date and on bot activity, not on the change under test. It is production-data health, so it is **Monitoring**. |
| F3 | `check_pipeline_tests` runs about 290 unit tests of the events-discovery automation. That automation does not ship with the website. | `check_pipeline_tests.py` | A failing automation test currently stops website deploys; it caused 7 of the 10 recent deploy failures. See D4. |
| F4 | seo_check per-page `[FAIL]` means "one of 8 checks failed on this page" (87.5 = 7/8). The page status has no threshold and never affects the exit code. The gate is `aggregate >= 85 && no indexability violations`. | `seo_check.py:487,496,508-513` | Relabel the per-page status (FR-007). Run the same gate on PRs (FR-014). |
| F5 | `run_smoketests.py` discovers checks by `check_*.py` glob, with `--only` as a substring match. It has no category, tag, or exclude mechanism. agent-validate excludes checks with a shell `case`. | `run_smoketests.py:37-41`, `agent-validate.groovy:15-24` | A catalog-driven selector is needed (D3). |
| F6 | `check_exceptions.py` hard-fails the day after expiry, with no warning window and no stale-target detection. Both current exceptions target deleted workflow files and expire 2026-12-15. `check_security_policy` imports the same validator. | `check_exceptions.py:21-53`, `check_security_policy.py:18,39` | **Time bomb:** from 2026-12-16 every smoketest run, deploy and PR fails. FR-017 fixes this, and the stale entries are deleted. |
| F7 | The site is built by Hugo in: deploy/seo-check (production), deploy/smoketests (a separate worktree via `check_hugo_build`), the smoketests job, security-gate/built-site (production), and agent-validate. Checks that need built output and sort alphabetically before `check_hugo_build` print SKIP on a clean checkout. | `deploy.Jenkinsfile:118-168` | Build once, then point every check at that build (D2). |
| F8 | `check_artifact_cleanup` forbids `stash` or `archiveArtifacts` of `site/public`. `check_deploy_push_rebase`, `check_deploy_region` and `check_hugo_build` parse Jenkinsfiles by name and pattern. | commit 9f391a8 | The built site must pass between stages **in the same workspace** (`reuseNode true`), never by stash. The parsing checks must be retargeted from `deploy.Jenkinsfile` to the new file. |
| F9 | Every skip is a full build record: checkout plus a Gate stage, about 8s, and it counts toward the keep-N limit. `main` alternates between real runs and bot or no-change skips. | `builds/42/build.xml` (NOT_BUILT "no site/** changes") | Stop creating the build at all for bot commits (D5). |
| F10 | Prometheus already scrapes Jenkins (`monitoring/prometheus.yml:97-103`, 15s). It exposes `default_jenkins_builds_last_stage_result_ordinal{jenkins_job,stage}` and `…_last_build_result_ordinal`, for the last build only. There is no Jenkins dashboard. The only CI alert is `jenkins_down`. | `/prometheus/` scrape, `health-alerts.yml:249-290` | An overview dashboard needs no new exporter (D6). |
| F11 | pipeline-graph-view 1038 gives a per-run stage graph and logs, plus a per-job "Stages" runs × stages table (`showGraphOnJobPage`, currently off). It has no folder-level overview. No dashboard-view or build-monitor plugin is installed. | plugin jar, `PipelineGraphViewConfiguration` absent | Put all delivery stages in **one** job so the per-job table *is* the per-change single pane (D1). |
| F12 | archive and purge botPush content to `main` **before** the gates run, so a failed gate leaves content committed but not deployed. | `deploy.Jenkinsfile:83-116` | Acceptable. The next delivery deploys it. Kept, and documented in the stage catalog. |

## Decisions

### D1 — Consolidate per-change work into one `delivery` pipeline
- **Decision**: Replace `deploy`, `smoketests`, `security-gate` and `terraform` with one multibranch job, `blogLosAngeles/delivery` (`ci/jenkins/delivery.Jenkinsfile`). It runs on PRs and `main` with fixed stages:
  1. `Prepare`
  2. `Maintain content` (main only)
  3. `Build`
  4. `Checks` (parallel: `tests`, `security`, `seo`)
  5. `Infrastructure`
  6. `Deploy` (main only)
  7. `Verify` (main only)

  Stages that don't apply are skipped via `when`, and pipeline-graph-view shows them as *skipped*. It reports one GitHub status, `jenkins/delivery`.
- **Rationale**: Jenkins has no cross-job pane (F11), but pipeline-graph-view's per-run graph plus the per-job stage table give exactly the single pane FR-008/FR-009 ask for, once every stage lives in one job. This also:
  - removes the duplicate smoketests run
  - makes PR gates identical to deploy gates (FR-014)
  - collapses four skip-heavy histories into one
- **Alternatives considered**:
  - An orchestrator job calling the six jobs with `build job:`. Rejected: the per-change state stays spread across six histories, and the parent graph shows only a "triggered" step.
  - Installing the Build Monitor or Dashboard View plugins. Rejected: they show job-level colors only, not stages, and add plugins to pin.
  - A Grafana-only pane. Rejected as the *primary* pane: Prometheus exposes only the last build's stages (F10), with no per-change history.

### D2 — Build once, and point checks at the build
- **Decision**:
  - The `Build` stage does the single production build (`rm -rf site/public && HUGO_ENVIRONMENT=production hugo --minify --gc`) into the workspace.
  - Every check stage uses `agent { docker { image …; reuseNode true; args '-u 0:0' } }` on the same workspace.
  - `check_hugo_build.py` honours `CI_PREBUILT=1`: it still verifies the version pins and that `site/public/index.html` exists, but does not rebuild. The worktree trick is removed.
- **Rationale**: This meets FR-013 and fixes the alphabetical SKIP problem (F7). `reuseNode` keeps F8's no-stash rule.
- **Alternatives considered**: rebuilding inside `check_hugo_build` into a temp `--destination`. Rejected: the site would still be built twice.

### D3 — A machine-read check catalog is the source of truth
- **Decision**:
  - Add `ci/checks.yml` to blogLosAngeles. It has one entry per check with `id`, `stage`, `category` (blocking | advisory | monitoring), `scope` (paths that make it blocking), `threshold`, `runs_on`, `purpose` and `waiver`.
  - A new shared-library step, `runCheck(id) { … }`, reads the entry and maps the check's exit code to a stage result using that category (see [contracts/check-result-contract.md](contracts/check-result-contract.md)).
  - `run_smoketests.py` gains `--category` and `--exclude` driven by the catalog.
  - A new smoketest, `check_catalog_coverage.py`, fails if any `check_*.py`, `runCheck` id or Jenkinsfile stage is missing from the catalog, or if the catalog names something that doesn't exist.
  - `scripts/ci/render_catalog.py` generates `docs/ci-gates.md`, and the coverage check asserts it is in sync.
- **Rationale**: The rules exist once and are enforced by the step that runs the check. SC-006's "observed behaviour matches documented category" then holds by construction, and adding a check without classifying it fails CI (US4 scenario 2).
- **Alternatives considered**:
  - A hand-written markdown table only. Rejected: it drifts, which is the current state.
  - Categories hard-coded in the Jenkinsfile. Rejected: an agent or reviewer can't read them.

### D4 — Initial classification of every check
- **Decision**:

  | Class | Checks |
  |---|---|
  | **Blocking** | Hugo build failure; `internal_links`, `indexable_page_metadata`, `jsonld_structured_data`, `xml_declaration` and the other built-output checks; the SEO gate (aggregate ≥85, zero indexability violations); gitleaks; osv-scanner HIGH+; checkov curated list; policy/exception validity; `check_built_site`; the Jenkinsfile/terraform static checks; `scripts_tests`, `archive_events_tests`, `edm_parser_tests`, `security_policy`; content checks that ship broken pages (`missing_cover_images`, `cover_image_format`, `event_date_offsets`) |
  | **Blocking when the change touches `automation/events-discovery/`, otherwise advisory** | `pipeline_tests`, `source_shard_coverage`, `unparsable_sources`, `performer_sourced` |
  | **Advisory** | per-page SEO issues, keyword report, checkov non-curated findings, `gsc_health_tests` (skips with no node) |
  | **Monitoring** (scheduled, alert-only) | `surfaced_backlog` (moved to a `data-health` job), live security headers (`security-live`), live SEO crawl, weekly fresh-advisory dependency rescan |
- **Rationale**: FR-002 says a check blocks when it evaluates what ships. The automation tests guard code that never ships with the site. They should still block a PR *that changes that code*, but not every website deploy (F3). The spec Assumptions were refined here: pipeline tests stay blocking **for changes to the automation**.
- **Alternatives considered**:
  - Keep `pipeline_tests` always blocking (the spec's original assumption). Rejected: it reproduces 7 of the 10 recent deploy blocks.
  - Make it purely advisory. Rejected: automation PRs would lose their gate.

### D5 — Stop skip noise at the source
- **Decision**:
  - In seed.groovy, add `buildStrategies { ignoreCommitterStrategy { ignoredAuthors('jenkins-bot@chadrbean.com'); allowBuildIfNotExcludedAuthor(false) } }` together with the existing skip-initial-indexing strategy (basic-branch-build-strategies 317 includes it). Bot commits then never create a build.
  - `skipIfBotCommit()` stays as a second line of defence.
  - Pushes with no `site/` change are **real** delivery runs: tests, security and SEO run, and deploy is skipped *with a reason*. So they are not noise.
  - Site-health jobs use the `:main` suffix so PR branches are never indexed.
- **Rationale**: This meets FR-012 and SC-005 without deleting history.
- **Verify at implementation**: the strategy class name in the installed plugin version (`jenkins/plugins.txt:7`). If it is absent, fall back to bumping the plugin, and document the fallback.
- **Alternatives considered**: a `buildDiscarder` that deletes NOT_BUILT runs. Rejected: Jenkins has no such built-in behaviour, and it would hide the fact that anything ran.

### D6 — Two views: a per-change pane and a site-health overview
- **Decision**:
  1. **Per-change pane**: the `blogLosAngeles/delivery` job page, which pipeline-graph-view shows by default (it has no JCasC settings; see the T003 correction below). The run page (pipeline-graph-view console) links each stage to its log.
     - `runCheck` sets a build badge/summary naming the blocking check when the run failed (FR-010).
  2. **Overview dashboard**: a Grafana dashboard at `monitoring/dashboards/ci-blog-delivery.json` (Ops folder). It shows:
     - delivery/main last-build stage matrix (`last_stage_result_ordinal`)
     - last result and age per open PR
     - site-health job status (security-live, seo-live-crawl, data-health)
     - 30-day success-rate trend (`success_build_count_total` / `total_build_count_total`)
  3. **Folder landing**: a `listView` inside `blogLosAngeles` with columns status / last success / last failure / last duration, split into *Delivery* and *Site health*.
- **Rationale**: This meets FR-008, FR-010 and FR-011. It needs no new plugins, and the Prometheus scrape already exists (F10).
- **Alternatives considered**: switching `markupFormatter` to safe HTML for linked folder descriptions. Deferred: it widens the XSS surface for small gain.

### D7 — Result semantics and exit-code contract
- **Decision**: checks use exit codes `0` pass, `1` findings, `2` tool error or unusable input, `3` inconclusive (external source unreachable), `4` not applicable (no input). `runCheck` maps (category × exit code × change scope × override) to the stage result:

  | Category | Exit 1 | Exit 2 | Exit 3 | Exit 4 |
  |---|---|---|---|---|
  | Blocking | FAILURE | FAILURE, labelled *errored* | UNSTABLE *inconclusive*, with an email on main | SUCCESS *n/a* |
  | Advisory | UNSTABLE | UNSTABLE, labelled *errored* | UNSTABLE *inconclusive* | SUCCESS *n/a* |
  | Monitoring | FAILURE (runs only in scheduled jobs, so it never blocks a change) plus `notifyFailure` email | same as Monitoring exit 1 | same as Monitoring exit 1 | SUCCESS *n/a* |

  Scripts to adapt: `summarize.py` (keeps 0/1/2), the zizmor wrapper (empty input → 4), osv-scanner (DB unavailable → 3), `check_live_site.py` (unreachable → 3), seo_check (no build → 2).
- **Rationale**: This meets FR-003, FR-006 and FR-009, and gives *errored* its own label in the stage (edge case).

### D8 — Emergency override
- **Decision**:
  - `delivery` gets a string parameter `OVERRIDE_REASON`. It only takes effect when `triggeredBy() == 'manual'` on `main`.
  - When it is set, `runCheck` downgrades Blocking FAILURE to UNSTABLE for that run.
  - The run gets a red "OVERRIDE" badge, and its description is set to the reason and the user (`BUILD_USER` from the cause).
  - `notifyFailure`-style email goes out even on success.
- **Rationale**: This meets FR-018. It is recorded in build history and visible in both panes.
- **Alternatives considered**: a `DRY_RUN`-style skip-gates flag. Rejected: it would leave no record of which check was bypassed.

### D9 — Waivers
- **Decision**: extend `check_exceptions.py`:
  - **warn** (exit 0, prints WARN, `runCheck` → advisory UNSTABLE on the `policy` sub-check) when a waiver expires within 14 days
  - **warn** when the `finding` path no longer exists (stale)
  - keep **fail** on expired
  - delete the two stale zizmor entries now, which removes the 2026-12-16 time bomb (F6)
- **Rationale**: This meets FR-017 and US4 scenario 3.

### D10 — Site-health jobs and alerting
- **Decision**:
  - `blogLosAngeles/security-live:main` (after deploy + weekly) and `seo-live-crawl:main` (weekly) are kept.
  - New `data-health:main` runs daily and executes the `monitoring` category via `run_smoketests.py --category monitoring`.
  - Security-gate's weekly cron becomes `delivery`'s daily cron on main (the daily rebuild already exists), with osv's "DB unavailable" → inconclusive.
  - Alerts use the existing `notifyFailure()` SES email for any site-health failure, plus one Grafana rule, `ci_site_health_failing`, in `monitoring/provisioning/alerting/`. It fires when any site-health job's last result is FAILURE for 24h, as a backstop if email is silent.
- **Rationale**: This meets FR-005 and FR-011 and reuses the existing channel (spec assumption).
- **Alternatives considered**: exporting the backlog count as a Prometheus metric. Deferred: it's useful later, and not needed to stop the blocking.

### D11 — Migration and cutover
- **Decision**: a single cutover PR per repo, ordered:
  1. blogLosAngeles PR:
     - add `delivery.Jenkinsfile`, `data-health.Jenkinsfile`, `ci/checks.yml` and the script changes
     - retarget the Jenkinsfile-parsing smoketests to `delivery.Jenkinsfile`
     - keep the old Jenkinsfiles in place until step 3
  2. localsetup PR:
     - seed: `blogLosAngeles: ['delivery', 'security-live:main', 'seo-live-crawl:main', 'data-health:main']`
     - build strategies
     - `runCheck`
     - JCasC pipeline-graph-view config
     - dashboard, alert, docs, drawio
     - then `POST /configuration-as-code/reload` and a manual first build (per memory: a new seed entry 404s until reload)
  3. blogLosAngeles follow-up: delete the retired Jenkinsfiles, and disable the old jobs in Jenkins (Job DSL's default `removedJobAction` is IGNORE, so delete them manually after one green delivery run).
- **Rationale**: Only one job deploys at any time, because the old `deploy` stops being seeded in the same step where `delivery` appears.

## Setup verification (T002–T004, 2026-09-25)

- **T002 (D5):** basic-branch-build-strategies 317 has **no** ignore-committer strategy. Its classes are All, Any, Branch, ChangeRequest, Named, None, SkipInitialBuildOnFirstBranchIndexing and Tag. The strategy ships in the separate `ignore-committer-strategy` plugin (Job DSL: `ignoreCommitterStrategy { ignoredAuthors('…'); allowBuildIfNotExcludedAuthor(false) }`). **Fallback taken:** add that one plugin, pinned, to `jenkins/plugins.txt`. This is the only new plugin in the feature.
- **T003 (D6), corrected 2026-09-26:** pipeline-graph-view 1038 has **no** JCasC configurator (as F11 already found). An `unclassified.pipelineGraphView` block made `ConfigurationAsCode.init` fail and Jenkins boot-loop on deploy. The block was removed. The stage graph and the job-page stage table are on by default, so nothing needs configuring.
- **T004 (F10):** result ordinals, checked against on-disk builds:
  - `…_last_build_result_ordinal` uses the hudson `Result` ordinal: 0 SUCCESS, 1 UNSTABLE, 2 FAILURE, 3 NOT_BUILT, 4 ABORTED.
  - `…_last_stage_result_ordinal` uses the pipeline-rest-api `StatusExt` ordinal: 0 NOT_EXECUTED (skipped), 1 ABORTED, 2 SUCCESS, 3 IN_PROGRESS, 4 PAUSED_PENDING_INPUT, 5 FAILED, 6 UNSTABLE.
  - Verified: deploy/main #42's Gate stage (success) = 2 and its skipped stages = 0; smoketests/main's failed stage = 5.
- **T035 correction to D5 (2026-09-25):** two details in the D5 sketch were wrong.
  - basic-branch-build-strategies **ORs** a bare list of strategies. The ignore-committer strategy must therefore be ANDed with `skipInitialBuildOnFirstBranchIndexing()` inside `buildAllBranches { strategies { … } }` (symbol read from the jar).
  - `allowBuildIfNotExcludedAuthor` must be **true**. Per the plugin help, `false` means "don't build if the changeset contains any ignored-author commit", which would also skip a human push that happened to include a bot commit.
  - Pinned `ignore-committer-strategy:63.v7e87d06b_a_30c`: no `@Symbol`, so Job DSL exposes it as `ignoreCommitterStrategy`. It requires core ≥ 2.492.3, and we run 2.568.3.
