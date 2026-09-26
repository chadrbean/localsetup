# Contract: stage names and check ids per project

- Stage names follow spec 001 (`contracts/delivery-stages.md`): Prepare → Build → Checks/<group> → Infrastructure → Deploy → Verify. A stage that does not apply is omitted.
- The Grafana `ci-overview` stage table shows whatever stage names exist, so renaming a stage only changes the rows.
- Every id listed below must exist in that repo's `ci/checks.yml`; `runCheck` fails the run otherwise.

## aws-infrastructure / terraform (main + PRs, automatic)

| Stage | Checks (category) |
|---|---|
| Prepare | — (bot-commit skip, `terraform init`) |
| Checks » lint | `tf-fmt` (blocking), `tf-validate` (blocking) |
| Checks » security | `checkov` (blocking), `trivy-config` (blocking) |
| Infrastructure | `tfPlanApply`: plan + PR comment always; apply on a main push only when no blocking check failed |

## aws-infrastructure / drift (main, manual + monthly cron)

| Stage | Checks |
|---|---|
| Verify | `tf-drift` (monitoring): exit 1 on drift, and 2 on a terraform error |

## localsetup / ci (main + PRs, automatic)

| Stage | Checks |
|---|---|
| Prepare | — |
| Checks » security | `gitleaks` (blocking), `trivy-config` (advisory, `.trivyignore.yaml`) |
| Checks » lint | `shellcheck` (blocking), `check-syntax` (blocking) |

## zca-accounting / ci (main + PRs, manual only: Principle XX)

| Stage | Checks | Tier |
|---|---|---|
| Prepare | `manualOnly()` allow-list | always |
| Checks » tests | `go-vet`, `go-test`, `web-typecheck`, `web-test` (all blocking) | always |
| Checks » security | `gosec`, `govulncheck`, `pnpm-audit` (advisory) | RUN_QUALITY |
| Checks » quality | `go-lint`, `eslint`, `prettier`, `docs-currency`, `diagram-currency`, `commitlint` (advisory); `tf-fmt-validate`, `region-policy`, `shellcheck` (blocking) | RUN_QUALITY |
| Checks » e2e | `web-e2e`, `go-test-integration` (advisory) | RUN_QUALITY |

`deploy-dev`, `deploy-prod` and `local-refresh` keep their stages. Their gate becomes the shared `manualOnly()`.
