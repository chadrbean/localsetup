<!--
SYNC IMPACT REPORT
Version change: 1.0.0 → 1.0.1 (2026-09-26)
Bump rationale: PATCH. This clarifies Principle IX's shellcheck rule: it covers scripts we
maintain, and excludes the vendored spec-kit `.specify/` now that it is committed (the
agent-pipeline onboarding contract needs it in the repo). No principle was added or removed.
Modified principles: IX. Docs & Contracts Stay Current (scope of the shellcheck rule).
Added/removed sections: none.
Templates: none changed. The same exclusion is applied in ci/checks.yml,
ci/jenkins/agent-validate.groovy and docs/ci-gates.md.
Follow-up TODOs: none new.

Version change: (unfilled template) → 1.0.0
Bump rationale: initial ratification. The principles codify the rules that CLAUDE.md and the
runbooks already enforce. Specs 001 and 002 checked themselves against these rules because this
file was still the template.
Modified principles: none (the template had no principles).
Added principles:
  I. Everything as Code, Nothing Out-of-Band (NON-NEGOTIABLE)
  II. Secrets & Short-Lived Credentials (NON-NEGOTIABLE)
  III. Sensitive-Data Minimisation (NON-NEGOTIABLE)
  IV. Catalog-Driven Gates
  V. Contained Autonomous Agents (NON-NEGOTIABLE)
  VI. Rootless, Local-First, Reproducible Stacks
  VII. Verified Observability
  VIII. Cost-Aware Routing
  IX. Docs & Contracts Stay Current
Added sections: Platform Constraints; Development Workflow & Quality Gates; Governance
Removed sections: none
Templates: .specify/templates/plan-template.md reads this file at runtime, so no change needed.
Follow-up TODOs:
  - DONE 2026-09-26: the floating LiteLLM image tags are pinned to the versions that were
    running (litellm-database v1.99.1, postgres 16.15, redis 7.4.8-alpine) (Principle VI).
  - The blog deploy region us-west-1 is a recorded exception (specs/001 plan.md). Revisit it if
    the bucket provider moves.
-->

# localsetup Constitution

## Core Principles

### I. Everything as Code, Nothing Out-of-Band (NON-NEGOTIABLE)

- Jenkins MUST be configured only through JCasC (`jenkins/casc/`). A job exists only if it is
  listed in `jenkins/casc/github/seed.groovy`. UI edits MUST NOT be relied on, because they are
  lost on restart.
- AWS IAM users, roles and DNS records MUST come from Terraform in `~/git/aws-infrastructure`.
  Nothing is created out-of-band in the console or CLI.
- Alerting MUST be Grafana unified alerting, provisioned from `monitoring/provisioning/alerting/`.
  Dashboards that matter MUST be git-tracked in `monitoring/dashboards/`.
- The only sanctioned UI change: add missing GitHub Project Status options in the UI. Never use
  `updateProjectV2Field`, which replaces the whole option list.

**Rationale**: this is a single-operator home lab. Any state that is not in git cannot be
rebuilt, reviewed or diffed after a disk loss or a container recreate.
**Source**: `docs/CICD.md`, `docs/SECURITY-MONITORING.md`, `docs/AGENT-PIPELINE.md`.

### II. Secrets & Short-Lived Credentials (NON-NEGOTIABLE)

- Secrets MUST live in the git-ignored `.env` inside each stack, with a committed
  `.env.example` that names the variables and gives no values.
- New static AWS access keys MUST NOT be created. CI and host MUST authenticate through IAM
  Roles Anywhere certificates issued by `scripts/jenkins_ca.sh`.
- Pipelines MUST reach AWS only through `withAwsRole('<key>')`. A new key needs all four steps:
  the `aws-roles.json` entry, the cert, the trust statement, and the `ci_jenkins_role_names`
  entry.
- Reference copies of live configs (for example `hermes/config.yaml`) MUST keep secret fields
  blank.
- gitleaks is a blocking check. An entry MUST be added to `.gitleaksignore` only after the value
  is out of the working tree, with a note saying whether it was rotated or accepted.

**Rationale**: the repo is pushed to GitHub. Long-lived keys and committed secrets are the most
likely way this account gets compromised.
**Source**: `docs/CICD.md` § AWS auth, `CLAUDE.md` § AWS.

### III. Sensitive-Data Minimisation (NON-NEGOTIABLE)

- The LiteLLM gateway MUST log metadata only. Prompt and response logging MUST NOT be enabled,
  in any sink.
- Values an attacker controls (client IP, Host header, request path, user agent) MUST NOT be
  Loki labels. They stay in the log line.
- Health and uptime probes MUST NOT trigger paid model calls. Use `/health/readiness`, never
  `/health`.

**Rationale**: the gateway carries bank and tax data. Unbounded labels also break Loki and let an
attacker inflate storage.
**Source**: `docs/OBSERVABILITY.md` §2–§4, `docs/SECURITY-MONITORING.md` §4.

### IV. Catalog-Driven Gates

- In a repo with `ci/checks.yml`, every check MUST run through `runCheck(id:)` /
  `runCatalogStage(stage:)`. Its catalog `category` (blocking / advisory / monitoring) alone
  decides fail vs warn.
- Check scripts MUST use the exit-code contract: 0 pass, 1 findings, 2 error, 3 inconclusive,
  4 n/a.
- Checks against production data or the live site MUST NOT be blocking. They are `monitoring`
  and belong in a site-health job.
- Reports MUST go through `publishReports(...)` in `post { always }`.
  - Do not call `junit`, `recordIssues` or `publishHTML` directly.
  - Catalog repos MUST NOT use `failOnNewIssues:`.
- Accepted findings MUST be recorded in the tool's ignore file, with a path and a statement.
- Pipelines MUST use the shared library (`jenkins/shared-library/vars`) for AWS auth, PR
  comments, bot pushes, path filters and manual-only guards (`manualOnly()`) instead of
  re-implementing them.

**Rationale**: one catalog keeps the written policy and the pipeline's behaviour from drifting,
and red builds stay meaningful.
**Source**: `docs/CICD.md` § Check catalog & gating, `docs/ci-gates.md`,
`specs/001-blog-pipeline-visibility/`, `specs/002-all-project-pipelines/`.

### V. Contained Autonomous Agents (NON-NEGOTIABLE)

- Headless Claude MUST run only inside `localhost/ci-claude*` images, with `IS_SANDBOX=1`, and
  with no GitHub, AWS or podman credentials. Push, PR and board updates MUST stay in the pipeline.
- The per-repo gate `ci/jenkins/agent-validate.groovy` MUST be loaded from the target repo's
  `main`, never from the agent's branch.
- Only repos in the allowlist `jenkins/shared-library/resources/agent/config.json` may be
  checked out.
- Agent commits MUST be authored by `jenkins-agent@chadrbean.com`, never `jenkins-bot`.
- Agents MUST NOT weaken gates, and MUST NOT deploy.

**Rationale**: model output is untrusted input. Containment keeps a bad run limited to one PR a
human reviews.
**Source**: `docs/AGENT-PIPELINE.md` § Security model.

### VI. Rootless, Local-First, Reproducible Stacks

- Stacks MUST run under rootless `podman-compose`, started from each stack's directory.
- Persistent data MUST be bind-mounted from `~/.local/share/<app>/`, not named volumes.
- Published ports MUST bind to `127.0.0.1`. Traefik is the only public entry point.
- A new `*.chadrbean.com` app MUST touch all four places:
  - the `traefik/dynamic.yml` router and service
  - the `/etc/hosts` hairpin
  - the `aws-infrastructure` DNS record
  - `DNS_RECORDS` in `scripts/awsChadHomeIp.sh`
- Container images SHOULD be version-pinned. New floating tags MUST NOT be added.
- CI build images are `localhost/ci-*:1`, built locally and not pushed. Container steps use
  `args '-u 0:0'` so workspace files stay owned by host uid 1000.

**Rationale**: the host must be rebuildable from git plus `~/.local/share`. Loopback binding keeps
every service behind Traefik's TLS and fail2ban.
**Source**: `CLAUDE.md` § Stacks & conventions, `docs/CICD.md`.

### VII. Verified Observability

- Every change to a dashboard or alert rule MUST pass `scripts/verify_dashboard.py --alerts`
  before merge.
- Grafana threshold rules MUST NOT use `eq`. Use `within_range`, because an `eq` rule sits in
  error state and never fires.
- Alert email MUST go through Amazon SES in `us-west-2`, sent from `hermes@chadrbean.com`.
- A new alert MUST be shown to fire (or its query shown to match) at least once. The result is
  recorded with a date in the relevant runbook.

**Rationale**: an alert that cannot fire is worse than none, because it creates false
confidence.
**Source**: `docs/OBSERVABILITY.md`, `docs/SECURITY-MONITORING.md` §7 and §9,
`docs/KOPIA-MONITORING.md`.

### VIII. Cost-Aware Routing

- Each AI task MUST be routed to the cheapest model that is good enough for it.
- Every consumer MUST have its own key and budget in LiteLLM.
- Work that is not interactive SHOULD use off-peak windows, batch APIs and prompt caching where
  they apply.

**Rationale**: the gateway exists to get the most value per dollar. Unbounded spend by one
consumer must be impossible.
**Source**: `README.md`, `docs/MODELS.md`, `docs/OFF-PEAK.md`, `docs/USAGE.md`.

### IX. Docs & Contracts Stay Current

- Each change MUST update, in the same PR:
  - `README.md`
  - `CLAUDE.md`
  - the relevant `docs/*.md`
  - the architecture diagram `docs/monitoring.drawio`
- Pipeline stage names and catalog check ids are contracts with the Grafana dashboards and
  alerts. They MUST be renamed together.
- `.sh` files we maintain MUST be shellcheck-clean at warning level. Vendored, upstream-managed
  tooling (spec-kit's `.specify/`) is excluded, because refreshes overwrite local edits. The
  exclusion MUST be the same in `ci/checks.yml` and `ci/jenkins/agent-validate.groovy`. Every
  tracked YAML, JSON and Python file MUST parse (`python3 ci/check_syntax.py`).

**Rationale**: the docs are the runbooks used during an outage. A stale runbook is a new outage.
**Source**: `CLAUDE.md`, `ci/checks.yml`.

## Platform Constraints

- **AWS region**: `us-west-2` only, including SES identities and the SMTP relay. The only
  recorded exception is the blog's deploy bucket in `us-west-1`
  (`specs/001-blog-pipeline-visibility/plan.md`).
- **AWS account**: `188627879503`. SES is in sandbox mode, so only verified recipients can
  receive mail.
- **Jenkins JCasC**: only keys listed under "Available attributes" or at
  `/configuration-as-code/reference` may be used. An unknown key makes Jenkins boot-loop.
  Rebuilds use `podman-compose up -d --build --force-recreate`.
- **Job DSL / seed**: use only strategy and filter names that have an `@Symbol`. The `:main` and
  `:manual` flags keep the semantics in `specs/002-all-project-pipelines/contracts/`.
- **Rootless podman uid mapping**: host uid 1000 is uid 0 in containers. A container that reads
  a `chmod 600` bind-mounted secret runs as `user: "0"`.

## Development Workflow & Quality Gates

- Non-trivial features follow Spec Kit, in order: `/speckit-specify`, `/speckit-plan` (which
  includes a Constitution Check), `/speckit-tasks`, `/speckit-implement`. Artifacts live in
  `specs/NNN-<name>/`.
- Branches are named `<type>/<short-kebab-desc>`, following `~/.claude/docs/GIT.md`. Changes land
  by PR. The `localsetup/ci` job MUST be green on every blocking check before merge.
- A pipeline stage that must not run after a failure MUST be guarded with
  `when { expression { currentBuild.currentResult != 'FAILURE' } }`, because `runCheck` records
  failures without throwing.
- In `post { always }`, `checkReport()` MUST come before `stepSummary()`.
- A CI failure may be called pre-existing only after checking the SHA the failing build ran on.

## Governance

- **Supremacy**: this constitution overrides informal conventions and prior chat context.
  `CLAUDE.md` and the `docs/` runbooks are runtime guidance. They add detail but MUST NOT
  contradict it. When they conflict, amend one or the other in the same PR.
- **Amendment procedure**: an amendment is a PR that does all of the following:
  1. edits this file
  2. bumps the version
  3. sets **Last Amended** to the merge date
  4. prepends a Sync Impact Report
  5. updates any Spec Kit template whose gates it changes
- **Versioning policy**: semantic versioning.
  - MAJOR: a principle is removed, or redefined in a way that is not backward compatible.
  - MINOR: a principle or section is added, or guidance is materially expanded.
  - PATCH: wording, clarification or typo fixes.
- **Compliance review**: every `/speckit-plan` MUST include a Constitution Check that marks each
  principle pass or fail. A violation MUST either be justified in the plan's Complexity Tracking
  table or resolved by an amendment, never by silently bypassing it. PR reviewers verify the
  NON-NEGOTIABLE principles on every change.

**Version**: 1.0.1 | **Ratified**: 2026-09-26 | **Last Amended**: 2026-09-26
