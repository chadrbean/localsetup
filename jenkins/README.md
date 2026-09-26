# jenkins/ — self-hosted CI/CD (replaces GitHub Actions)

Jenkins LTS in rootless podman, served at **https://jenkins.chadrbean.com** (Traefik →
`127.0.0.1:3010`). Code stays on GitHub. A GitHub App sends webhooks and receives
commit statuses. Builds get AWS access through **IAM Roles Anywhere**, which issues
short-lived STS credentials from a private CA, so no AWS keys are stored.
Runbook: [docs/CICD.md](../docs/CICD.md).

| Piece | Where |
|---|---|
| Controller image (Jenkins 2.568.3 LTS, docker CLI, gh, awscli, `aws_signing_helper`) | `Containerfile`, `plugins.txt` (pinned) |
| Config as code | `casc/base/jenkins.yaml` (always), `casc/github/` (GitHub App, shared library, job seed) |
| Jobs | `casc/github/seed.groovy` → `<repo>/<pipeline>` multibranch jobs for `ci/jenkins/<pipeline>.Jenkinsfile` |
| Shared library `@Library('ci')` | `shared-library/vars/*.groovy`, role map `shared-library/resources/aws-roles.json` |
| Run reports (tests, coverage, scanner issues, HTML) | `publishReports(...)` → junit / coverage / warnings-ng / htmlpublisher plugins ([docs/CICD.md § Run reports](../docs/CICD.md#run-reports)) |
| Build images | `images/ci-terraform`, `images/ci-hugo`, `images/ci-podman` → `localhost/ci-*:1` |
| Data (bind mount, same path in container) | `~/.local/share/jenkins/data` |
| Secrets (ro mount, chmod 700) | `~/.local/share/jenkins/secrets/` (`github-app.pem`, `roles-anywhere/<cn>.{pem,key}`) |
| CA (never mounted except `issued/`) | `~/.local/share/jenkins/ca/` — `scripts/jenkins_ca.sh` |

## How builds run

- Builds run on the built-in node (4 executors, label `podman`). Container steps
  (`agent { docker { image 'localhost/ci-hugo:1'; args '-u 0:0' } }`) are launched
  through the host's **rootless podman socket**.
- `-u 0:0` is container root, which is host uid 1000 under rootless podman, so
  workspace files stay owned by `chad`.
- `JENKINS_HOME` is mounted at the same absolute path inside the container. The
  workspace bind mounts that docker-workflow creates therefore resolve on the host.
- `withAwsRole('<key>') { ... }` runs `aws_signing_helper` inside the controller JVM:
  1. It uses the cert for that key's CN, the trust anchor and the `jenkins-ci` profile.
  2. It exports `AWS_*` session creds (1h by default, 2h maximum) into the block only.
  3. Because it runs in the controller, it works inside docker agents too.
  4. The STS session is named after the build (`BUILD_TAG`, sanitized, last 64 chars), so
     CloudTrail shows `assumed-role/<role>/jenkins-<job>-<n>` and each AWS call ties back to a
     build. Override with `[sessionName: '...']`.
- **Security trade-off:** whoever administers Jenkins can start containers as host
  uid 1000. Mitigations:
  - one admin (matrix auth)
  - no proxy auth: Jenkins' login is the only gate, so keep the admin password long and random
  - private repos only
  - the webhook is HMAC-verified

## First-time setup

```bash
# 1. dirs + secrets
mkdir -p ~/.local/share/jenkins/{data,secrets/roles-anywhere,ca/issued}
chmod 700 ~/.local/share/jenkins/{secrets,ca}
cp .env.example .env && chmod 600 .env   # fill JENKINS_ADMIN_PASSWORD, SES_SMTP_* (= monitoring/.env GRAFANA_SMTP_*)
systemctl --user enable --now podman.socket

# 2. images
podman build -t localhost/ci-terraform:1 images/ci-terraform
podman build -t localhost/ci-hugo:1 images/ci-hugo   # versions must match blogLosAngeles/.security/tool-versions.env
podman build -t localhost/ci-podman:1 images/ci-podman   # host podman from pipelines (zca-accounting local-refresh)
podman-compose up -d --build                         # http://127.0.0.1:3010 (admin / .env password)
```

3. **Create the GitHub App** at github.com → Settings → Developer settings → GitHub Apps → New:
   - **Name:** `chadrbean-jenkins`
   - **Homepage:** https://jenkins.chadrbean.com
   - **Webhook URL:** `https://jenkins.chadrbean.com/github-webhook/`
   - **Webhook secret:** `GITHUB_WEBHOOK_SECRET` from `.env`
   - **Repository permissions:**
     - Checks: RW
     - Commit statuses: RW
     - Contents: RW (the blog bot commits)
     - Pull requests: RW (plan comments)
     - Issues: RW (drift issues)
     - Metadata: R
   - **Subscribe to events:** Push, Pull request, Check run, Check suite, Repository
   - **Install only on:** aws-infrastructure, blogLosAngeles, zca-accounting, localsetup (localsetup is needed to load the shared library).
   - Generate a private key and convert it to PKCS#8, which Jenkins requires:

     ```bash
     openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt \
       -in ~/Downloads/chadrbean-jenkins.*.private-key.pem \
       -out ~/.local/share/jenkins/secrets/github-app.pem
     chmod 600 ~/.local/share/jenkins/secrets/github-app.pem
     ```

   - Set `GITHUB_APP_ID` and `CASC_PATHS=/casc/base,/casc/github` in `.env`, then run `podman-compose up -d`.
4. **Roles Anywhere:** see [docs/CICD.md § AWS auth](../docs/CICD.md#aws-auth--iam-roles-anywhere).

## Updating

- **Jenkins or plugins:** bump the `FROM` tag in `Containerfile`, then:
  1. Remove the versions from `plugins.txt`.
  2. Build.
  3. Re-pin `plugins.txt` from the resolved versions (see git history of this file for the one-liner).
  4. Run `podman-compose up -d --build`.
- **JCasC:** edit `casc/`, then `podman restart jenkins`. UI changes are overwritten on every restart.
- **New pipeline:** add it to the `pipelines` map in `casc/github/seed.groovy`, add `ci/jenkins/<name>.Jenkinsfile` to the repo, then `podman restart jenkins`.
- **Shared library:** changes must reach `main` of this repo on GitHub. To test from a branch, use `@Library('ci@<branch>') _`.

## Backups

Kopia's hourly `/home/chad` snapshot covers `~/.local/share/jenkins`. The
`~/.local/share/jenkins/data/.kopiaignore` file skips rebuildable workspaces, caches and logs.
The CA key is passphrase-encrypted. If you lose it, `init` a new CA and re-apply the trust anchor.
