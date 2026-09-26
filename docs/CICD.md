# CI/CD — Jenkins + IAM Roles Anywhere

On 2026-09-24, GitHub Actions was replaced with self-hosted Jenkins because of GitHub billing failures and unneeded cost. Code stays on GitHub. The stack is in [`jenkins/`](../jenkins/README.md).

```
GitHub (code, PRs) --webhook (GitHub App, HMAC)--> Traefik jenkins.chadrbean.com --> Jenkins 127.0.0.1:3010
Jenkins --statuses/PR comments/bot pushes (App installation token)--> GitHub
Jenkins --X.509 cert--> IAM Roles Anywhere (us-west-2 trust anchor) --> STS 1-2h creds --> repo deploy role
Jenkins --podman socket--> build containers (localhost/ci-hugo:1, ci-terraform:1, python/node/golang)
```

## Pipelines

| Jenkins job | Replaces | Trigger | AWS role key |
|---|---|---|---|
| `aws-infrastructure/terraform` | terraform.yml | PR + main. Prepare → Checks {lint: tf-fmt, tf-validate; security: checkov, trivy-config} → Infrastructure (plan + PR comment always; apply on a push to main when nothing blocking failed) | `aws-infrastructure` |
| `aws-infrastructure/drift` | drift-detection.yml | `:main:manual`: cron `H 8 1 * *` + manual. Monitoring check `tf-drift`: drift turns the run **red** + SES email + GitHub issue | `aws-infrastructure` |
| `blogLosAngeles/delivery` | deploy.yml, seo-check.yml, smoketests.yml, security-gate.yml, terraform.yml | PR + main. Cron `H 13 * * *`, manual `DRY_RUN` / `OVERRIDE_REASON`. Prepare → Maintain content → Build → Checks {tests, security, seo} → Infrastructure (`terraform/**`) → Deploy (main, `site/**`) → Verify | `blog-deploy`, `blog-terraform` |
| `blogLosAngeles/security-live` | security-live.yml | main only: after deploy + Mon `H 14`. Site health (alerts, never blocks) | — |
| `blogLosAngeles/seo-live-crawl` | seo-live-crawl.yml | main only: Mon `H 15`. Site health | — |
| `blogLosAngeles/data-health` | — (new) | main only, daily `H 12` + manual. Site health: production-data checks, red + email, never blocks a change | — |
| `zca-accounting/ci` | ci.yml | `:manual` (Constitution Principle XX): Build with Parameters only. Prepare → Checks {tests; with `RUN_QUALITY`: security, quality, e2e}; categories in its `ci/checks.yml` | — |
| `zca-accounting/deploy-dev`, `deploy-prod`, `local-refresh` | deploy-*.yml | `:main:manual`; guarded by the shared `manualOnly()` (+ `CONFIRM_APPLY` / `input`) | `zca-dev`, `zca-prod` |
| `localsetup/ci` | — (new) | PR + main. Prepare → Checks {security: gitleaks (blocking), trivy-config (advisory, `.trivyignore.yaml`); lint: shellcheck, check-syntax (blocking)}. Rules: `docs/ci-gates.md` | — |
| `agent/feature-dispatcher` | — (new) | cron `H/5`; claims Ready cards on the GitHub Project boards (WIP per repo) → starts `feature-worker`. See [AGENT-PIPELINE.md](AGENT-PIPELINE.md) | — |
| `agent/feature-worker` | — (new) | from the dispatcher or manual (`REPO`, `ISSUE`); spec-kit via headless Claude Code → repo's `agent-validate.groovy` → PR → card to In review | — |
| `ci-maintenance/cert-expiry` | — | Mon `H 9`; fails/emails at <30 days | — |
| `ci-maintenance/aws-role-smoke` | — | manual; `aws sts get-caller-identity` per role key | any |

- **Seed flags** (`jenkins/casc/github/seed.groovy`, contract `specs/002-all-project-pipelines/contracts/seed-job-flags.md`):
  - **`name:main`** discovers only `main`.
  - **`name:manual`** never builds on a push, PR event or branch indexing, so those events leave no NOT_BUILT entries in history.
    - It works through an unsatisfiable `buildAllBranches { buildRegularBranches(); buildChangeRequests{} }`: nothing is both a branch and a PR.
    - Manual *Build*, `build job:` (upstream) and Jenkinsfile `cron` triggers still run.
    - Flagged `:manual`: all zca-accounting jobs, `aws-infrastructure/drift` and the blog site-health jobs.
- **Manual-only guard:** `manualOnly()` (shared library) is an allow-list (`manual`, `upstream` by default). Any other trigger ends NOT_BUILT with the reason. It backstops `:manual`.
- **Cross-project view:**
  - Grafana **CI — overview (all projects)** (`monitoring/dashboards/ci-overview.json`) shows each job's latest main result, stages of each per-change pipeline, time since last run/success, scheduled staleness, pass rate and duration.
  - Alerts in `monitoring/provisioning/alerting/ci-alerts.yml`:
    - `ci_main_failing`: a per-change pipeline is red on main for 10 min.
    - `ci_monitoring_failing`: drift or cert-expiry is red.
    - `ci_scheduled_stale`: drift quiet > 35 d, cert-expiry quiet > 8 d.
    - `ci_site_health_failing`: blog site health.
- **Crons** are UTC. The controller runs with `TZ=UTC`.
- **GitHub status contexts:** each job posts its own `jenkins/<pipeline>`. Branch protection required checks should use these names.
- **Failure emails:** failures on main and on scheduled builds email `ALERT_EMAIL_TO` via SES (`notifyFailure()`). PR failures show on the PR.
- **Bot commits:** the blog's archive/purge steps push to main as `jenkins-bot` with `[skip ci]`. The seed's build strategy (`ignore-committer-strategy` plugin, ANDed with skip-first-indexing through `buildAllBranches`) means those pushes create **no build at all**. `skipIfBotCommit()` in each pipeline remains a backstop that marks any that slip through NOT_BUILT.

### GitHub Actions concept map

| GitHub Actions | Jenkins (shared library `@Library('ci')`) |
|---|---|
| `configure-aws-credentials` + OIDC | `withAwsRole('<key>', [region:, duration:]) { }` |
| `GITHUB_TOKEN` | `withGitHubToken { }` (App installation token as `GH_TOKEN`) |
| `github-script` PR comment | `prComment(file:)` |
| `on.*.paths` | `pathsChanged([...])` / `changedFiles()` |
| `github.event_name` | `triggeredBy()` → `scm` / `indexing` / `cron` / `manual` / `upstream` |
| `$GITHUB_STEP_SUMMARY` | set the env var to `${WORKSPACE}/summary.md` + `stepSummary()` (archives it and shows its first line on the build page) |
| terraform workflow | `tfPlanApply(dir:, role:, preChecks:)`:<br>• Plan and comment on PRs **always**, even when fmt/validate/scanners report findings (the build fails afterwards). The comment includes the `runCheck` table when earlier catalog stages ran.<br>• Apply only on a push to main, and never after a blocking check failed.<br>• With `preChecks` (legacy) it also runs checkov/trivy itself. Catalog repos run them as `runCheck` stages instead.<br>• plan/apply use `-lock-timeout=10m`, so jobs sharing a state wait instead of failing. |
| test/scan report uploads | `publishReports(junit:, coverage:, eslint:, checkov:, trivy:, gitleaks:, html:)` in `post { always }` |
| `continue-on-error` / required vs optional checks | `runCheck(id:)` / `runCatalogStage(stage:)`: the category in the repo's `ci/checks.yml` decides block vs warn (see below) |
| `concurrency` | `options { disableConcurrentBuilds() }` |
| `environment` approval | `input` step (zca prod) |

### Run reports

Plugins: `junit`, `coverage`, `warnings-ng`, `htmlpublisher`, `badge` (pinned in
`jenkins/plugins.txt`), plus `pipeline-graph-view` for the stage graph. Pipelines don't
call them directly. Emit the formats below and call `publishReports(...)` in
`post { always { } }`. Inputs whose glob matches nothing are skipped.

| Input | Format | Tool flag | Shows up as |
|---|---|---|---|
| `junit:` | JUnit XML | vitest `--reporter=junit --outputFile=…`, playwright `reporter: [['junit', …]]` | **Test Result** + job trend |
| `coverage:` | Cobertura XML | vitest `--coverage.reporter=cobertura` | **Coverage** + trend |
| `eslint:` | checkstyle or JSON | `eslint -f checkstyle -o …` | **ESLint** issues |
| `shellcheck:` | checkstyle | `shellcheck -f checkstyle … > shellcheck.xml` | **ShellCheck** issues |
| `checkov:` / `trivy:` / `gitleaks:` | SARIF | `checkov -o cli -o sarif --output-file-path console,checkov.sarif`, `trivy … --format sarif --output trivy.sarif`, `gitleaks … --report-format sarif --report-path gitleaks.sarif` | one Issues page per tool, new/fixed vs the previous build |
| `html: [[dir:, index:, name:]]` | static HTML | e.g. `playwright-report/` | sidebar link, kept per build |

- `failOnNewIssues: true` marks the build UNSTABLE when a scanner finds an issue the
  reference build didn't have. **Don't use it in a repo with `ci/checks.yml`**: the catalog
  decides the colour. The gate is also sticky, because its reference build must have passed the
  gate itself. That kept `localsetup/ci` yellow on 7 of 8 runs.
- **Reference build:** a PR compares against its target branch's job (`<repo>/<job>/main`).
  Other builds compare against their own previous build.
- `label:` prefixes the issue ids and names. Use it when one build publishes the same
  tool twice. `tfPlanApply` passes its `dir`.
- **HTML report CSP:** `docker-compose.yml` relaxes `hudson.model.DirectoryBrowserSupport.CSP`
  so report JS runs. The sandbox omits `allow-same-origin`, so the scripts get an opaque
  origin and can't reach the Jenkins session. Only publish reports your own builds generate.

### Check catalog & gating (`runCheck`)

A repo declares its checks in `ci/checks.yml`. blogLosAngeles, aws-infrastructure, zca-accounting and localsetup all do, and each repo explains its rules in its own `docs/ci-gates.md` (spec 002). Each entry has a `category`, and pipelines run the entry through `runCheck(id: '…')` (one check) or `runCatalogStage(stage: '…')` (every check in a stage). `runCheck` maps the check's exit code to a stage result according to that category, so the written rule and the pipeline's behaviour can't drift. Schema and rules: `specs/001-blog-pipeline-visibility/contracts/`.

| Category | Meaning | Exit 1 findings | Exit 2 error | Exit 3 inconclusive | Exit 4 n/a |
|---|---|---|---|---|---|
| `blocking` | Evaluates the change. Failing means the site ships broken, insecure or unindexable | FAILURE | FAILURE | UNSTABLE | SUCCESS |
| `advisory` | Reported, never stops anything | UNSTABLE | UNSTABLE | UNSTABLE | SUCCESS |
| `monitoring` | Site-health jobs only. Alerts, never blocks a change | FAILURE | FAILURE | FAILURE | SUCCESS |

Exit 0 is always SUCCESS.

- **`scope: [paths]`** (blocking only): the check blocks only when the PR or push touches those paths. Otherwise it is advisory, and it is always advisory on cron and manual runs. Example: the events-discovery unit tests never block a website-only change.
- **Failures don't stop siblings.** Every check runs. The first blocking failure sets the badge and description to `Blocked by <id> (<stage>)`. `checkReport()` (call it in `post { always }` before `stepSummary()`) puts a verdict line and a per-check table at the top of `summary.md`.
- **Emergency override:** do a manual *Build with Parameters* on `main` with `OVERRIDE_REASON` set. Blocking failures then become UNSTABLE, and the run gets a red `OVERRIDE <id>: <reason> (<user>)` badge. `notifyOverride()` emails `ALERT_EMAIL_TO`. The parameter is ignored on PRs and on non-manual runs.
- An id that isn't in `ci/checks.yml` is a pipeline error, so uncatalogued checks can't run.

## AWS auth — IAM Roles Anywhere

This is free. AWS stores only the CA **certificate**, and every private key stays on this host.

- **CA:** `scripts/jenkins_ca.sh`. The root CA lives in `~/.local/share/jenkins/ca/` with a passphrase-protected key and 10-year validity. Leaf certs are valid for 180 days.
- **Terraform:** module `aws-infrastructure/terraform/modules/ci-roles-anywhere` (us-west-2) creates:
  - trust anchor `jenkins-ca`
  - profile `jenkins-ci` (7200s) and profile `host-admin` (3600s)
  - role `host-admin-terraform`, trusted only for CN `chad-host-terraform`
- **Existing roles:** each keeps its GitHub OIDC statement during the parallel run and gains a Roles Anywhere statement:

  ```json
  { "Effect": "Allow",
    "Principal": { "Service": "rolesanywhere.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"],
    "Condition": {
      "ArnEquals":    { "aws:SourceArn": "<trust anchor ARN>" },
      "StringEquals": { "aws:PrincipalTag/x509Subject/CN": "jenkins-<key>" } } }
  ```

| Role key | IAM role | Cert CN | Trust change lives in |
|---|---|---|---|
| aws-infrastructure | github-actions-deploy-role | jenkins-aws-infrastructure | aws-infrastructure `modules/iam` |
| blog-deploy | otbla-github-actions-deploy | jenkins-blog-deploy | blogLosAngeles `terraform/modules/iam` |
| blog-terraform | otbla-github-actions-terraform | jenkins-blog-terraform | blogLosAngeles (**apply locally**: the role can't modify itself) |
| zca-dev / zca-prod | github-oidc-deploy-{dev,prod} | jenkins-zca-{dev,prod} | zca-accounting `infra/modules/github-oidc` (also needs `max_session_duration = 7200`) |
| (host) | host-admin-terraform | chad-host-terraform | aws-infrastructure module |

### Bootstrap (one time)

```bash
scripts/jenkins_ca.sh init
cp ~/.local/share/jenkins/ca/ca.pem ~/git/aws-infrastructure/ci/jenkins-ca.pem   # public cert; commit it
for cn in jenkins-aws-infrastructure jenkins-blog-deploy jenkins-blog-terraform jenkins-zca-dev; do
  scripts/jenkins_ca.sh issue "$cn" --jenkins
done
scripts/jenkins_ca.sh issue chad-host-terraform --host
```

1. In aws-infrastructure, set the `enable_ci_roles_anywhere` default to `true`. Then run, still with the static `terraform` user, and **only once**:

   ```bash
   terraform apply -target=module.ci_roles_anywhere -target=module.iam
   ```

2. Copy the outputs `ci_rolesanywhere_trust_anchor_arn` and `…_jenkins_profile_arn` into `jenkins/.env` as `RA_TRUST_ANCHOR_ARN` and `RA_PROFILE_ARN`. Then run `podman-compose up -d`.
3. Point the host at Roles Anywhere in `~/.aws/config`:

   ```ini
   [default]
   region = us-west-2
   credential_process = aws_signing_helper credential-process --certificate /home/chad/.local/share/aws-roles-anywhere/chad-host-terraform.pem --private-key /home/chad/.local/share/aws-roles-anywhere/chad-host-terraform.key --trust-anchor-arn <ta> --profile-arn <host_admin_profile_arn> --role-arn <host_admin_role_arn>
   ```

   Install the helper on the host at `/usr/local/bin/aws_signing_helper`, the same binary as in `jenkins/Containerfile`. Remove the static keys from `~/.aws/credentials`.
4. Check that `aws sts get-caller-identity` shows `assumed-role/host-admin-terraform/...`.
5. Using the Roles Anywhere identity, apply the trust statements in each app repo with `-var rolesanywhere_trust_anchor_arn=<ta>`. Then make that ARN the variable's default, so CI plans don't try to remove the statement.
6. Run `ci-maintenance/aws-role-smoke` for each key.
7. Deactivate the `terraform` user's access key:

   ```bash
   aws iam update-access-key --user-name terraform --access-key-id <id> --status Inactive
   ```

   Delete the key after a week without problems.

### Renewal / break-glass

- **Renewal:** `scripts/jenkins_ca.sh issue <cn> --jenkins|--host` replaces the cert in place. No AWS change is needed. `cert-expiry` emails 30 days before a cert expires.
- **Host cert expired, or Roles Anywhere broken:** sign in to the AWS console as root. Re-activate the `terraform` user's key, or create a temporary one, fix the problem, then deactivate it again.
- **CA key lost:** run `init` for a new CA, replace `ci/jenkins-ca.pem`, and apply the trust anchor, using break-glass creds if needed.

## Cutover checklist (per repo)

1. Merge the repo's `jenkins-migration` branch. Jobs appear after the next branch index; the first scan does not build.
2. Watch the first PR and main builds, and the `jenkins/<pipeline>` statuses on GitHub.
3. In branch protection, switch the required checks to the Jenkins contexts. (Skip this step for private repos on the free plan, such as blogLosAngeles: they have no branch protection or rulesets (HTTP 403), so no checks are required.)
4. `gh workflow disable <name> -R chadrbean/<repo>` for each Actions workflow. Don't delete them yet.
5. After 2 clean weeks:
   - delete `.github/workflows/`
   - remove the GitHub OIDC trust statements and roles
   - remove the account OIDC provider (aws-infrastructure `modules/iam/main.tf`, import block in `imports.tf`)

### Retiring a job

Job DSL's `removedJobAction` is IGNORE, so a job dropped from `seed.groovy` stays in Jenkins, with its history and workspaces. To remove it:

1. Remove it from `seed.groovy` and delete its `ci/jenkins/<name>.Jenkinsfile`. Merge both.
2. Check nothing builds or waits on it. Grep for `build job: '<repo>/<name>` and for the job name in dashboards and alerts.
3. With no build running, move `~/.local/share/jenkins/data/jobs/<repo>/jobs/<name>` to `~/.local/share/jenkins/archive/<date>-<why>/`, then `podman restart jenkins`. Moving the folder keeps the history recoverable. Delete the archive once nothing needs it.

Example: on 2026-09-26 the blog's `deploy`, `smoketests`, `security-gate` and `terraform` jobs (7.3 GB) were archived to `archive/2026-09-26-blog-retired-jobs/`.

### Where is my change? (blogLosAngeles)

1. **Grafana → Ops → "CI — blog delivery"** shows everything on one screen: every stage of the latest `delivery/main` run (red = the stage that blocked), open PRs, site-health jobs, and the 30-day pass rate.
2. **Jenkins → blogLosAngeles → Overview**, then `delivery`. The job page has a runs × stages table (pipeline-graph-view). Each run's description says what happened: *deployed*, *PR checks*, *no site/ changes: checks only*, or *Blocked by `<id>`*.
3. **Open the run.** The stage graph shows where it stopped, the `Blocked by <id> (<stage>)` badge names the check, and the summary starts with a per-check table giving category, verdict and exit code. Click the red stage for its log.
4. **What does the check guard, and can it be waived?** See blogLosAngeles `docs/ci-gates.md`.

### Override runbook (blogLosAngeles `delivery`)

Use this only when a blocking check fails, the site must ship anyway, and a waiver in `.security/exceptions.json` doesn't fit:

1. Jenkins → `blogLosAngeles/delivery/main` → **Build with Parameters**. Set `OVERRIDE_REASON` to the why and the follow-up (e.g. `hotfix broken homepage; fix check_x in PR #123`).
2. The run deploys with blocking failures downgraded to UNSTABLE. It carries a red `OVERRIDE <id>: <reason> (<user>)` badge, and `notifyOverride()` emails `ALERT_EMAIL_TO`.
3. Fix the underlying failure. The override applies to that one run only; the next push is gated normally.

## Troubleshooting

| Symptom | Check |
|---|---|
| blogLosAngeles run badged `Blocked by <id>` | Look up `<id>` in blogLosAngeles `docs/ci-gates.md`. Exit 2 (*errored*) is a tool or setup problem, not a finding: check the image and version pins. Reproduce locally with `python3 scripts/run_smoketests.py --only <id with _>`, or the catalog `command`. |
| Advisory check red instead of yellow, or the reverse | The category comes from `ci/checks.yml` at the commit being built. Check the entry and its `scope`. Scoped checks only block PRs and pushes that touch their paths. |
| `runCheck: '<id>' is not in ci/checks.yml` | Every check must be catalogued. Add the entry and run `python3 scripts/ci/render_catalog.py`. |
| Check shows *errored (exit 2)* for a plain test failure | `make` exits 2 whenever a recipe fails. A make-based catalog command must map that to 1 (`make X \|\| exit 1`). Otherwise findings are reported as tool errors. |
| `terraform validate` check is *inconclusive* on a reused workspace | `init -backend=false` still loads the S3 backend recorded in an earlier run's `.terraform/`. Give validate its own data dir: `export TF_DATA_DIR=.terraform-validate` (aws-infrastructure `tf-validate`). |
| zca `web-e2e` / `go-test-integration` *errored*: "offset host port(s) … already in use" | Another zca e2e run holds the stack on ports 15432, 16379 and the rest. Only one e2e run can be up at a time. Rerun once the other build has finished. |
| New PR branch: *Build with Parameters* returns 400 | A branch that has never been built has no parameter definitions yet. Click *Build* once, then use parameters. |
| Webhook deliveries fail (GitHub App → Advanced) | `curl -si https://jenkins.chadrbean.com/github-webhook/` should be 405/200, not 401. Also check the Traefik `jenkins` router, DNS `jenkins`, and the `/etc/hosts` hairpin. |
| `aws_signing_helper failed … AccessDenied` | The role's trust policy lacks the CN statement, or the ARN default wasn't set. Also check the cert CN (`openssl x509 -subject -noout -in …`) and that the role is in the `jenkins-ci` profile (`ci_jenkins_role_names`). |
| `…DurationSeconds exceeds MaxSessionDuration` | Raise the role's `max_session_duration`, or request less (`withAwsRole(key, [duration: 3600])`). |
| Container step `permission denied` in workspace | The agent is missing `args '-u 0:0'`. |
| JCasC boot loop (`UnknownAttributesException`) | `podman logs jenkins \| grep -A2 SEVERE`. An attribute was renamed after a plugin bump. |
| Downstream job (e.g. `security-live` after `deploy`) ends NOT_BUILT "push is not a trigger" | `triggeredBy()` must match `BuildUpstreamCause` too; `getBuildCauses()` doesn't match subclasses. |
| `Jenkins Down` alert | `podman ps -a --filter name=jenkins; podman logs --tail 100 jenkins` |
