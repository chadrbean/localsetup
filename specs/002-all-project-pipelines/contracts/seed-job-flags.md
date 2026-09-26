# Contract: seed job flags

This contract covers `jenkins/casc/github/seed.groovy`. Each entry has the form `'<name>[:main][:manual]'`, and the flags can appear in any order.

| Entry | Discovers | Automatic builds (push, PR event, indexing) | Manual / upstream / cron |
|---|---|---|---|
| `ci` | main + PR-* | yes: PRs from their first commit; branches skip only their first sighting; jenkins-bot-only pushes never | yes |
| `x:main` | main | yes (same exceptions) | yes |
| `x:manual` | main + PR-* | **never** | yes |
| `x:main:manual` | main | **never** | yes |

Implementation:

- **`:manual`** replaces the job's `buildStrategies` with `buildAllBranches { buildRegularBranches(); buildChangeRequests {...} }`, an AND that no head satisfies, because a head is either a branch or a PR. Only strategies with a `@Symbol` are used: the exact-name filter has none, and an unverified Job DSL name would fail the seed at boot.
- **Non-manual entries** use `buildAllBranches { buildAnyBranches { buildChangeRequests; skipInitialBuildOnFirstBranchIndexing }; ignoreCommitterStrategy }`. `skipInitialBuildOnFirstBranchIndexing` skips the first revision of every new head, even when a webhook reports it, so it must never apply to PRs on its own: until 2026-09-26 it did, and no PR's first commit was built. It still stops branches (main) building on their first sighting, so a job being (re)created never fires a deploy or apply.
- **Cron:** cron triggers declared in a Jenkinsfile (`triggers { cron(...) }`) keep working. They are timer triggers, not branch events.
- **Upstream:** `build job: '<repo>/<x>/main'` keeps working.
- **After a seed change:** a changed entry needs `POST /configuration-as-code/reload`, or a Jenkins restart. A new job also needs "Scan Multibranch Pipeline Now" before its first build.
