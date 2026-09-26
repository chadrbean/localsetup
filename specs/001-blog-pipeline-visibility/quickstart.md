# Quickstart: Validating the Blog Pipeline Redesign

These scenarios run end to end, and together they prove the spec's user stories and success criteria. Each one names the requirement it proves. For names and semantics, see [contracts/delivery-stages.md](contracts/delivery-stages.md) and [contracts/check-result-contract.md](contracts/check-result-contract.md).

## Prerequisites

- The localsetup PR is merged and deployed:
  - seed + JCasC changes (see the memory note: after a seed change, run `POST /configuration-as-code/reload`, and trigger the first build of a new job manually)
  - shared library (`runCheck`)
  - dashboard and alert (`podman restart monitoring_grafana`)
- The blogLosAngeles PR that adds `delivery.Jenkinsfile`, `data-health.Jenkinsfile` and `ci/checks.yml` is merged.
- The old jobs `deploy`, `smoketests`, `security-gate` and `terraform` are disabled in Jenkins.

## Offline checks (no Jenkins)

Run these in `~/git/blogLosAngeles`:

```bash
python3 scripts/run_smoketests.py --exclude-category monitoring     # expect exit 0 on a clean main
python3 scripts/run_smoketests.py --only catalog_coverage           # catalog ↔ checks ↔ Jenkinsfiles ↔ docs in sync
python3 scripts/ci/render_catalog.py --check                        # docs/ci-gates.md up to date
python3 scripts/security/check_exceptions.py                        # no stale/expiring waivers (WARN lines only if any)
```

Run these in `~/git/localsetup`:

```bash
python3 ci/check_syntax.py
scripts/verify_dashboard.py --dashboard monitoring/dashboards/ci-blog-delivery.json --from now-24h --alerts
```

## Scenario 1 — A data-health problem does not block (US1-1, FR-005, SC-002)

1. On a branch, raise the backlog above 400 by adding dummy `surfaced` future events to `automation/events-discovery/state.json`, and open a PR that also changes a post.
2. **Expect**:
   - `delivery` for that PR is green.
   - `surfaced-backlog` does not appear in `Checks › tests`.
3. Run `blogLosAngeles/data-health/main` manually against the same data (or wait for the daily run).
4. **Expect**:
   - The job fails, and a failure email arrives (`notifyFailure`).
   - The dashboard's *Site health* row turns red.
5. Close the PR without merging.

## Scenario 2 — A real defect blocks and is named within a minute (US1-3, US2-2, FR-010, SC-003)

1. Open a PR that adds a broken internal link to a post.
2. **Expect**:
   - `delivery` fails.
   - The job page stage table shows `Checks › tests` red.
   - The run badge reads `Blocked by internal-links (checks/tests)`.
   - Clicking the stage opens the log line naming the broken href.
3. Time a person unfamiliar with the setup going from the job page to the failing href. It should take ≤ 60 s.

## Scenario 3 — Advisory and inconclusive results warn, never fail (US1-2, US1-4, FR-003, FR-006, FR-007)

1. Have a PR that only triggers checkov non-curated findings (the current state). **Expect**: `Checks › security` is yellow (UNSTABLE, "passed with warnings"), and the build does not fail.
2. Run `delivery` manually with the osv advisory DB blocked (e.g. temporarily set `OSV_OFFLINE=1`). **Expect**:
   - `deps` is marked *inconclusive*, and the stage is yellow.
   - The deploy still proceeds.
3. Read the deploy log's SEO output. **Expect**: pages with one issue are shown as `ISSUES`, not `FAIL`.

## Scenario 4 — PR result predicts deploy result (US3-1, FR-014, SC-004)

1. Merge a green content PR with no other merge in between.
2. **Expect**:
   - `delivery/main` is green, and `Deploy` and `Verify` ran.
   - `security-live/main` was triggered, via the link recorded in `Verify`.
3. Confirm the same `Checks › seo` gate ran on the PR run and on the main run (same stage, same threshold line).

## Scenario 5 — One build, no duplicate runs, no skip noise (US3-2, US3-3, FR-012, FR-013, SC-005)

1. Merge a content-only change. **Expect**:
   - One `delivery` run on main, with `Infrastructure` skipped ("no terraform changes").
   - The log shows exactly one `hugo --minify --gc` invocation.
2. **Expect**: the archive/purge bot commits (`[skip ci]` by jenkins-bot) create **no** new build in any job.
3. After one week, count the NOT_BUILT runs in the `delivery/main` history. They should be ≤ 10%:

   ```bash
   cd ~/.local/share/jenkins/data/jobs/blogLosAngeles/jobs/delivery/branches/main/builds
   grep -l NOT_BUILT */build.xml | wc -l; ls -d [0-9]* | wc -l
   ```

## Scenario 6 — Terraform-only change (edge case, FR-015)

1. Open a PR that changes only `terraform/`. **Expect**: `Infrastructure` shows the plan with a PR comment.
2. Merge it. **Expect**: `Infrastructure` applies, `Deploy` is skipped ("no site changes"), and `Checks` still ran first.

## Scenario 7 — Emergency override is recorded (FR-018)

1. With a known blocking failure on main, click **Build with Parameters** and set `OVERRIDE_REASON="hotfix: <why>"`.
2. **Expect**:
   - `Deploy` runs.
   - The run carries a red `OVERRIDE` badge naming the bypassed check and the reason.
   - An email arrives.
   - The dashboard's last-run row shows UNSTABLE.
3. Set `OVERRIDE_REASON` on a PR build. **Expect**: it is ignored, and the log explains why.

## Scenario 8 — Waivers warn before they break (US4-3, FR-017)

1. Temporarily set a waiver's `expires` to 10 days from today. **Expect**: `check_exceptions.py` prints `WARN … expiring` and exits 0. The stage stays green, because the exit-code contract has no "passed with warnings" code; the WARN line appears in the log and in the `security_policy` smoketest output.
2. Point a waiver's `finding` at a nonexistent path. **Expect**: a WARN containing "stale".
3. Set `expires` to yesterday. **Expect**: a FAIL (blocking).

## Scenario 9 — Every check is catalogued (US4-1, US4-2, SC-006)

1. Add an empty `scripts/smoketests/check_dummy.py` with no catalog entry. **Expect**: `catalog-coverage` fails, naming `check_dummy.py`.
2. Open `docs/ci-gates.md`, pick any stage shown in the pane, and find its checks with their category and threshold.

## Success-criteria measurement (after 2 weeks)

Take these from on-disk build records or Prometheus `default_jenkins_builds_*`:

| SC | Measure | Target |
|---|---|---|
| SC-001 | green `delivery/main` runs ÷ runs whose failure was not a genuine defect in the change | ≥ 90% |
| SC-002 | failures attributable to monitoring-class checks or verdict mismatches | 0 |
| SC-004 | merged PRs where the PR and main `delivery` results agree | ≥ 95% |
| SC-005 | NOT_BUILT runs ÷ all runs, per job | ≤ 10% |
| SC-007 | median merge→deployed time vs the 2026-09 baseline of successful `deploy` runs | ≤ baseline |
