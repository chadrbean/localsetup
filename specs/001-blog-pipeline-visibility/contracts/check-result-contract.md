# Contract: Check exit codes and the `runCheck` step

## Exit codes (every check script)

| Code | Meaning | Examples |
|---|---|---|
| 0 | pass (warnings may be printed as `WARN`) | summarize.py with `Blocking: 0` |
| 1 | blocking findings | gitleaks leak, broken link, SEO aggregate < 85 |
| 2 | tool error / unusable input | SARIF unreadable, no build output for seo_check |
| 3 | inconclusive: an external dependency is unreachable | osv advisory DB down, otbla.com unreachable |
| 4 | not applicable: nothing to check | zizmor with no workflow files |

Output rule (FR-007): a non-blocking result is never printed with the literal token `FAIL`. Use `WARN` or `ISSUES`.

## Shared-library step: `runCheck`

Location: `localsetup/jenkins/shared-library/vars/runCheck.groovy`

```groovy
// Runs one catalogued check and maps its exit code to a stage result.
// id       – catalog id in ci/checks.yml (required)
// script   – shell to run; defaults to the catalog `command`
// catalog  – path, default 'ci/checks.yml'
def call(Map args)   // runCheck(id: 'internal-links', script: '...')
```

### Behaviour

1. Load the catalog entry. If it is missing, **error**: an uncatalogued check cannot run.
2. Resolve the effective category:
   - If `scope` is set and `changedFiles()` does not intersect it on a `scm` PR or push run, use `advisory`.
   - On `cron` and `manual` runs, a scoped check is also treated as `advisory`.
3. Run `sh(returnStatus: true, script: …)`.
4. Map the result:

   | Category | Exit 0 | Exit 1 | Exit 2 | Exit 3 | Exit 4 |
   |---|---|---|---|---|---|
   | blocking | SUCCESS | FAILURE | FAILURE ("errored") | UNSTABLE ("inconclusive") | SUCCESS ("n/a") |
   | advisory | SUCCESS | UNSTABLE | UNSTABLE ("errored") | UNSTABLE ("inconclusive") | SUCCESS ("n/a") |
   | monitoring | SUCCESS | FAILURE | FAILURE ("errored") | FAILURE ("inconclusive") | SUCCESS ("n/a") |

5. Apply the result:
   - For stage results use `catchError(buildResult: X, stageResult: X)` or `unstable()`, so parallel siblings still finish.
   - On the **first** blocking FAILURE, set the badge summary to `Blocked by <id> (<stage>)` with a link to the stage log, and set `currentBuild.description`.
6. Override: if `params.OVERRIDE_REASON` is set, the run is `manual`, and the branch is `main`, then a blocking FAILURE becomes UNSTABLE. The step adds an `OVERRIDE` badge naming the check and the reason, and appends to `env.OVERRIDDEN_CHECKS`.
7. Write one line per check to `summary.md` so `stepSummary()` can pick it up:

   ```
   | id | category | result | detail |
   ```

### Compatibility

- Report publishing stays in `publishReports()` inside `post { always }`, per the docs/CICD.md convention. `runCheck` does not call `junit` or `recordIssues`.
- `monitoring` checks may only run in site-health jobs (enforced by `check_catalog_coverage`).

## Shared-library step: `runCatalogStage` (added during /speckit-tasks)

The smoketest suite has about 30 checks with different categories, and some are path-scoped. A single aggregate exit code can't carry a category per check. So `Checks › tests` and the `data-health` job run each catalogued check through `runCheck` instead of calling `run_smoketests.py` as one command.

Location: `localsetup/jenkins/shared-library/vars/runCatalogStage.groovy`

```groovy
// Runs every catalog entry whose `stage` equals `stage`, in catalog order, each via runCheck.
// Checks without a `command` default to: python3 scripts/smoketests/check_<id with _>.py
def call(Map args)   // runCatalogStage(stage: 'checks/tests')
```

- Every check runs, even after a failure, so a single run reports all problems.
- The stage result is the worst mapped result across its checks.
- The badge names the first blocking failure, per `runCheck` rule 5.
- `run_smoketests.py` remains the local and agent-validate entry point. `--category` and `--exclude-category` give the same selection as the pipeline.
