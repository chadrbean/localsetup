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
| `aws-infrastructure/terraform` | terraform.yml | PR + push to main (`terraform/**`); apply on push to main | `aws-infrastructure` |
| `aws-infrastructure/drift` | drift-detection.yml | cron `H 8 1 * *` + manual; SES email + GitHub issue on drift | `aws-infrastructure` |
| `blogLosAngeles/deploy` | deploy.yml + seo-check.yml | push to main (`site/**`), cron `H 13 * * *`, manual `DRY_RUN` | `blog-deploy` |
| `blogLosAngeles/security-gate` | security-gate.yml | PR + main + Mon `H 14` | — |
| `blogLosAngeles/security-live` | security-live.yml | after deploy + Mon `H 14` | — |
| `blogLosAngeles/seo-live-crawl` | seo-live-crawl.yml | Mon `H 15` | — |
| `blogLosAngeles/smoketests` | smoketests.yml | PR + main | — |
| `blogLosAngeles/terraform` | terraform.yml | PR + main (`terraform/**`) | `blog-terraform` |
| `zca-accounting/ci`, `deploy-dev`, `deploy-prod` | ci.yml, deploy-*.yml | manual only (repo principle) | `zca-dev`, `zca-prod` |
| `localsetup/ci` | — (new) | PR + main. The checks: gitleaks history (fails on any leak not in `.gitleaksignore`), trivy config (report), shellcheck, `ci/check_syntax.py` | — |
| `ci-maintenance/cert-expiry` | — | Mon `H 9`; fails/emails at <30 days | — |
| `ci-maintenance/aws-role-smoke` | — | manual; `aws sts get-caller-identity` per role key | any |

- **Crons** are UTC. The controller runs with `TZ=UTC`.
- **GitHub status contexts:** each job posts its own `jenkins/<pipeline>`. Branch protection required checks should use these names.
- **Failure emails:** failures on main and on scheduled builds email `ALERT_EMAIL_TO` via SES (`notifyFailure()`). PR failures show on the PR.
- **Bot commits:** the blog's archive/purge steps push to main as `jenkins-bot` with `[skip ci]`. `skipIfBotCommit()` stops those commits from re-triggering pipelines.

### GitHub Actions concept map

| GitHub Actions | Jenkins (shared library `@Library('ci')`) |
|---|---|
| `configure-aws-credentials` + OIDC | `withAwsRole('<key>', [region:, duration:]) { }` |
| `GITHUB_TOKEN` | `withGitHubToken { }` (App installation token as `GH_TOKEN`) |
| `github-script` PR comment | `prComment(file:)` |
| `on.*.paths` | `pathsChanged([...])` / `changedFiles()` |
| `github.event_name` | `triggeredBy()` → `scm` / `indexing` / `cron` / `manual` / `upstream` |
| `$GITHUB_STEP_SUMMARY` | set the env var to `${WORKSPACE}/summary.md` + `stepSummary()` (archives it and shows its first line on the build page) |
| terraform workflow | `tfPlanApply(dir:, role:, preChecks:)`. Plan and comment on PRs; apply only on a push to main. With `preChecks` it also publishes checkov/trivy Issues pages. plan/apply use `-lock-timeout=10m` so jobs sharing a state wait instead of failing |
| test/scan report uploads | `publishReports(junit:, coverage:, eslint:, checkov:, trivy:, gitleaks:, html:)` in `post { always }` |
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
  reference build didn't have.
- `label:` prefixes the issue ids and names. Use it when one build publishes the same
  tool twice. `tfPlanApply` passes its `dir`.
- **HTML report CSP:** `docker-compose.yml` relaxes `hudson.model.DirectoryBrowserSupport.CSP`
  so report JS runs. The sandbox omits `allow-same-origin`, so the scripts get an opaque
  origin and can't reach the Jenkins session. Only publish reports your own builds generate.

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

## Troubleshooting

| Symptom | Check |
|---|---|
| Webhook deliveries fail (GitHub App → Advanced) | `curl -si https://jenkins.chadrbean.com/github-webhook/` should be 405/200, not 401. Also check the Traefik `jenkins` router, DNS `jenkins`, and the `/etc/hosts` hairpin. |
| `aws_signing_helper failed … AccessDenied` | The role's trust policy lacks the CN statement, or the ARN default wasn't set. Also check the cert CN (`openssl x509 -subject -noout -in …`) and that the role is in the `jenkins-ci` profile (`ci_jenkins_role_names`). |
| `…DurationSeconds exceeds MaxSessionDuration` | Raise the role's `max_session_duration`, or request less (`withAwsRole(key, [duration: 3600])`). |
| Container step `permission denied` in workspace | The agent is missing `args '-u 0:0'`. |
| JCasC boot loop (`UnknownAttributesException`) | `podman logs jenkins \| grep -A2 SEVERE`. An attribute was renamed after a plugin bump. |
| Downstream job (e.g. `security-live` after `deploy`) ends NOT_BUILT "push is not a trigger" | `triggeredBy()` must match `BuildUpstreamCause` too; `getBuildCauses()` doesn't match subclasses. |
| `Jenkins Down` alert | `podman ps -a --filter name=jenkins; podman logs --tail 100 jenkins` |
