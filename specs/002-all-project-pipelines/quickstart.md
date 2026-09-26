# Quickstart: validate spec 002

## Static checks, before merging

```bash
python3 ci/check_syntax.py                                   # YAML/JSON, incl. dashboard + catalogs
shellcheck -S warning $(git ls-files '*.sh')
bash $CLAUDE_JOB_DIR/tmp/groovyc.sh <Jenkinsfile|vars/*.groovy> # Groovy parses
python3 scripts/verify_dashboard.py --dashboard monitoring/dashboards/ci-overview.json --alerts
```

## Deploy

1. Merge the PRs in order: localsetup (shared library + seed + dashboard), then aws-infrastructure, then zca-accounting.
2. Pull localsetup main into the checkout Jenkins mounts. JCasC reads `jenkins/casc` from `/home/chad/git/localsetup`.
3. Restart Jenkins with `podman restart jenkins`, which re-runs the seed. Wait for `/login` to return 200.
4. Archive the stale PR items of the main-only jobs; see docs/CICD.md "Retiring a job".
5. Restart Grafana with `podman restart monitoring_grafana` so the alert rules load.

## Scenarios

| # | Action | Expected |
|---|---|---|
| 1 | Build `localsetup/ci/main` | SUCCESS, stages Prepare / Checks » security / Checks » lint, and a "All checks passed" summary. trivy-config passes because the ignore file covers its findings. |
| 2 | Build `aws-infrastructure/terraform/main` | SUCCESS, with the plan in Infrastructure. Apply runs only on a push, so a manual run only plans. |
| 3 | Build `aws-infrastructure/drift/main` by hand | SUCCESS if nothing has drifted. If it has drifted: FAILURE plus an email and an issue. |
| 4 | Build `zca-accounting/ci/main` by hand (RUN_QUALITY=false) | The tests stage runs 4 catalogued checks, and the result reflects only their blocking verdicts. |
| 5 | Push a commit to zca-accounting main (or watch the next one) | No new history entry in any zca-accounting job. |
| 6 | Open Grafana "CI — overview" | Every in-scope job has a row, and the stage table and ages are populated. |
| 7 | `ci-maintenance/aws-role-smoke` → Build with Parameters | The ROLE_KEY choices no longer include zca-prod. |
