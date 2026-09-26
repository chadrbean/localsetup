# CI gates — localsetup

The single source of truth is [`ci/checks.yml`](../ci/checks.yml). Job `localsetup/ci` runs every check through the shared-library step `runCheck`. That check's catalog category decides the colour of the run, so this page and the pipeline cannot disagree. A check that runs without a catalog entry fails the run. The same model is used by blogLosAngeles, aws-infrastructure and zca-accounting (specs 001 and 002).

| Category | A failure makes the run | Use for |
|---|---|---|
| blocking | red (FAILURE) | the change itself is broken or leaks something |
| advisory | yellow (UNSTABLE), never red | hardening advice, style |
| monitoring | red, but only in scheduled/site-health jobs | never used in a per-change job |

Every check's exit code means the same thing:

| Exit code | Meaning |
|---|---|
| 0 | pass |
| 1 | findings |
| 2 | tool error |
| 3 | inconclusive: an external source was unreachable (blocking checks → yellow) |
| 4 | not applicable |

## Checks

| Stage | Check | Category | Threshold | How to accept a finding |
|---|---|---|---|---|
| Checks » security | `gitleaks` | blocking | no secret in the full history outside `.gitleaksignore` | Add it to `.gitleaksignore` only once the value is out of the tree. Say whether it was rotated or accepted. |
| Checks » security | `trivy-config` | advisory | no Containerfile/compose finding outside `.trivyignore.yaml` | Add a `.trivyignore.yaml` entry with `paths` and a `statement` |
| Checks » lint | `shellcheck` | blocking | no warning or error in any `*.sh` we maintain (vendored spec-kit `.specify/` excluded) | inline `# shellcheck disable=SCxxxx` with a reason |
| Checks » lint | `check-syntax` | blocking | every Python/YAML/JSON file parses | none |

## Accepted findings

The accepted findings are listed in `.trivyignore.yaml`:

- **DS-0002, root user:** the CI images and Caddy run as root on purpose. In rootless podman, root is host uid 1000.
- **DS-0026, no HEALTHCHECK:** the CI images are throwaway containers, and liveness is monitored from outside.

Warnings used to come from a "no new issues" rule, which kept this job yellow on 7 of 8 runs. That rule is gone: the catalog decides.

## Where to look

- Build page: the summary starts with *All checks passed*, *Passed with warnings* or *Blocked by &lt;check&gt;*, followed by the per-check table.
- Grafana **CI — overview (all projects)**: the latest result, stages and freshness of every project.
- The `ci_main_failing` alert emails when this job is red on `main`.
