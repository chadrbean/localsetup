# Feature Specification: Blog Pipeline Visibility & Right-Sized Gating

**Feature Branch**: `docs/blog-pipeline-spec`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "we are starting to get quite a lot of failures in our blog pipelines and im having a hard time deploying and getting changes in our website. The way this is setup its also hard to understand where the process is at between the different stages of deploy, gating, security, seo, smoke tests, terraform. Can we take a better look at our Jenkins pipeline design 1. Improve our pipeline setup to be able to see a single pane view where these pipeline stages are at so we can easily identify and troubleshoot. 2. Organize this a little cleaner. 3. analyze our current pipelines and make sure we have good rules inplace that make it easy to understand testing and make sure we are not overblocking on our gating. https://jenkins.chadrbean.com/job/blogLosAngeles/"

## Current State (baseline, 2026-09-25)

These are recorded observations of the blog (otbla.com) delivery process. They set the baseline that the success criteria are measured against.

| Process (main branch) | Runs | Passed | Failed | Skipped (no work) |
|---|---|---|---|---|
| Deploy | 42 | 7 | 10 | 25 |
| Security gate | 38 | 4 | 7 | 27 |
| Smoke tests | 38 | 1 | 9 | 28 |
| Live-site security | 44 | 7 | 0 | 37 |
| Live SEO crawl | 31 | 1 | 0 | 30 |
| Infrastructure (terraform) | 36 | 0 | 0 | 36 |

Observed causes of blocked changes:

1. **Production-data health treated as a code gate.** A check that counts events stuck in the content backlog (406–549 against a limit of 400) caused 9 of 10 smoke-test failures. It blocked every recent PR (221, 223, 224) and 3 deploys. None of those changes touched that data.
2. **Content-pipeline unit tests** failed 7 deploys. Because smoke tests run inside the deploy, any failure there stops the site from publishing.
3. **False block in the security gate.** The infrastructure-config check reported "Blocking: 0" with only medium-severity warnings, yet it failed on both PRs and main. An empty workflow-audit result was treated as a failure. A narrow fix landed on 2026-09-25 (blogLosAngeles 19862f1), but the general rule that a check's pass/fail must match its own verdict is not yet enforced anywhere.
4. **Misleading output.** The SEO step prints per-page "FAIL" lines (score 87.5) in every deploy but does not block. Readers can't tell what actually gates.
5. **Fragmentation and noise:**
   - Six separate processes report independently. 60–100% of their history is "skipped" entries, and there is no combined view.
   - The site is built up to five times per change.
   - Smoke tests run twice per merge.
   - The SEO score threshold applies at deploy but not on PRs, so a green PR can still fail at deploy.
   - Two security exceptions refer to files that no longer exist.
6. **Gates can't be required on GitHub.** They report on PRs, but the repository plan cannot make them required checks there. Only the deploy actually enforces them.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Only real defects block a deploy (Priority: P1)

As the site maintainer, when I merge a change, it reaches the live site unless the change itself would publish a broken or insecure site. Problems in production data, flaky external services, or style warnings are reported and alerted on, but they never stop an unrelated change from shipping.

**Why this priority**: Right now most failures come from checks unrelated to the change being shipped. This is the direct cause of "having a hard time deploying", so fixing it restores the ability to ship.

**Independent Test**: Replay the recent failure causes against a harmless content change: the data backlog above its limit, a check that reports zero blocking findings, and the SEO warnings. The change must still deploy, and each condition must still be reported in the right place.

**Acceptance Scenarios**:

1. **Given** the content backlog is above its health limit, **When** a content-only change is merged, **Then** the change deploys and the backlog condition raises a monitoring alert instead of failing the deploy.
2. **Given** a security check reports zero blocking findings and some warnings, **When** it completes, **Then** its result is "passed with warnings", never "failed".
3. **Given** a change adds a leaked secret, a high-severity vulnerable dependency, a broken internal link, or a site that fails to build, **When** it is checked, **Then** it is blocked and the reason is named.
4. **Given** the live site or an external advisory data source is temporarily unreachable, **When** a change-triggered check needs it, **Then** the check reports "inconclusive, not blocking" and a scheduled run retries it.

---

### User Story 2 - One screen shows where a change is (Priority: P1)

As the maintainer, I open one page and see, for any PR or merged commit, every stage in delivery order:
- build
- tests
- security
- SEO
- infrastructure
- deploy
- post-deploy live checks

Each stage shows its current state. When something failed, I can see which stage stopped the change and open the failing check's details in one step.

**Why this priority**: "hard to understand where the process is at" is the second pain point. Without one view, every failure means checking six places.

**Independent Test**: Push a change that deliberately fails one check. Starting from the single view, a person unfamiliar with the setup must name the failing stage and open its failure details within 1 minute.

**Acceptance Scenarios**:

1. **Given** a merged change is mid-delivery, **When** I open the single view, **Then** I see every stage for that change with a state of waiting, running, passed, passed with warnings, failed, or skipped, and each skip includes a reason.
2. **Given** a deploy was stopped, **When** I view that change, **Then** the blocking stage and check are highlighted, with a direct link to the failing output.
3. **Given** several changes are in flight, **When** I open the view, **Then** the most recent changes on the main branch and open PRs are listed with their overall status.
4. **Given** scheduled monitoring runs (live security, SEO crawl, data health), **When** I open the view, **Then** their latest results appear in a separate "site health" area, not mixed into per-change delivery.

---

### User Story 3 - A clean, ordered delivery flow (Priority: P2)

As the maintainer, delivery follows one predictable order: PR checks, then merge, then deploy, then post-deploy verification. Scheduled monitoring sits beside it. Each check runs once per change, runs that did no work stay out of history, and the checks a PR passes are the same checks the deploy enforces.

**Why this priority**: This removes the duplicated work and "green PR, red deploy" surprises that make the process hard to trust. It builds on stories 1 and 2 but isn't needed to unblock shipping.

**Independent Test**: Take a PR that passes all PR checks. Merge it with no other changes and confirm the deploy passes. Confirm each check appears once for that change and no "nothing to do" entries were added to visible history.

**Acceptance Scenarios**:

1. **Given** a PR passes all its blocking checks, **When** it is merged with no other intervening changes, **Then** the deploy's gates pass too, because the same rules are evaluated.
2. **Given** a change touches only site content, **When** it is processed, **Then** infrastructure-only stages show as "not applicable" in the change's view and don't create separate history entries.
3. **Given** a merge, **When** delivery runs, **Then** the site is built once and every later check uses that same build.

---

### User Story 4 - Written, understandable gating rules (Priority: P3)

As the maintainer, I have one plain-language catalog of every check. Each entry says:
- what the check protects
- its category: blocking, advisory, or monitoring
- its threshold
- when it runs
- how to waive it temporarily, with an expiry date

**Why this priority**: This makes stories 1–3 durable. Without written rules, over-blocking creeps back in as checks are added.

**Independent Test**: Choose any check shown in the single view and find its catalog entry. The entry must match how the check actually behaved.

**Acceptance Scenarios**:

1. **Given** any check, **When** I look it up in the catalog, **Then** I find its category, threshold, where it runs, and its waiver procedure.
2. **Given** a new check is proposed, **When** it is added, **Then** it must be classified against the catalog's written blocking criteria before it can block.
3. **Given** a waiver has expired or refers to something that no longer exists, **When** checks run, **Then** a warning names the waiver ahead of the expiry date, and stale waivers are flagged for removal.

---

### Edge Cases

- **Daily scheduled rebuild with no code change:** it republishes the site (so date-driven content refreshes) and is labelled as a scheduled rebuild, not a code change.
- **Emergency deploy while a blocking check is failing:** a documented, logged override exists. It records who used it and why, and shows in the single view.
- **Infrastructure-only change:** it goes through infrastructure review and apply stages and doesn't trigger an unnecessary site deploy.
- **Automated bot commits** (archive or purge of old content): they don't trigger duplicate delivery runs, and they are visible as part of the deploy that made them.
- **Two merges close together:** the view shows which one is deploying and which is queued or superseded.
- **A check crashes (tool error) rather than finding a problem:** it reports "errored", distinct from "failed". A blocking check that errors still blocks, and the tool error is shown.
- **A monitoring check stays red for days:** it keeps alerting, but it doesn't turn per-change delivery red.

## Requirements *(mandatory)*

### Functional Requirements

**Gating rules**

- **FR-001**: Every check MUST be classified as exactly one of:
  - **Blocking**: stops the merge or deploy.
  - **Advisory**: reported on the change but does not stop it.
  - **Monitoring**: runs on a schedule or after deploy, and alerts without stopping any change.
- **FR-002**: A check MUST be Blocking only when it evaluates the change itself, and when failing it means the published site would be broken, insecure, or non-indexable. Checks on production data, live third-party availability, or style and score warnings MUST NOT be Blocking.
- **FR-003**: A check's final state MUST match its own reported verdict. A check reporting zero blocking findings MUST end as passed or passed-with-warnings.
- **FR-004**: The following MUST remain Blocking:
  - leaked secrets
  - high or critical dependency vulnerabilities
  - curated high-severity infrastructure misconfigurations
  - site build failure
  - broken internal links
  - indexability violations such as noindex or a blocked robots file on public pages
- **FR-005**: The content-backlog health check and other production-data checks MUST move to Monitoring, with alerts delivered through the existing alerting channel.
- **FR-006**: When a check depends on an unreachable external source, it MUST report "inconclusive". It MUST NOT block a change-triggered run, and scheduled runs MUST retry it.
- **FR-007**: Check output MUST NOT label a non-blocking result as "FAIL". Warnings are labelled as warnings.

**Single view**

- **FR-008**: One view MUST show, per change (PR or main commit), every delivery stage in order: build, tests, security, SEO, infrastructure, deploy, post-deploy verification.
- **FR-009**: Each stage MUST show one of: waiting, running, passed, passed with warnings, failed, errored, skipped (with reason), or not applicable.
- **FR-010**: When a change is stopped, the view MUST identify the stopping stage and check, and link directly to its failure details.
- **FR-011**: The view MUST show the latest scheduled monitoring results (live security, SEO crawl, data health) in a separate site-health area.
- **FR-012**: Runs that performed no work MUST NOT appear as entries in the view's history.

**Organization**

- **FR-013**: Each check MUST run once per change. The site MUST be built once per delivery run, and every later check MUST reuse that build.
- **FR-014**: The blocking checks evaluated on a PR MUST be the same set the deploy enforces, including SEO indexability.
- **FR-015**: Delivery stages MUST run in a fixed, documented order, and a stage MUST NOT start until the stages it depends on have succeeded.

**Rules catalog and waivers**

- **FR-016**: A single catalog MUST document each check's purpose, category, threshold, trigger, and waiver procedure. It MUST be kept current with every change to checks.
- **FR-017**: Waivers MUST carry an expiry date and a reason. Waivers that are expired or refer to nonexistent items MUST be reported, and a warning MUST appear at least 14 days before a waiver expires.
- **FR-018**: A documented emergency override MUST let a deploy proceed past a failing Blocking check. Each use MUST be recorded with the reason and shown in the single view.

### Key Entities

- **Change**: a PR or merged commit, or a scheduled or manual rebuild. It has a trigger type and an overall status.
- **Stage**: an ordered step in delivery (build, tests, security, SEO, infrastructure, deploy, verification). It holds a state per change.
- **Check**: one specific test within a stage. It has a category (Blocking, Advisory or Monitoring), a threshold, a trigger, and an owner purpose.
- **Verdict**: the result of a check for a change. It is passed, warned, failed, errored, inconclusive or skipped, with details and a link.
- **Waiver**: a temporary exception to a check. It has a reason, a scope and an expiry date.
- **Override**: a logged emergency bypass of a Blocking check for one deploy.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: ≥ 90% of merged changes with no real defect reach the live site without manual intervention. The baseline is 7 successful deploys out of 17 that ran.
- **SC-002**: Zero changes are blocked by production-data health or by a check whose own verdict was "no blocking findings". The baseline is 23 such blocks over 25–26 Sep 2026: 14 caused by data health and 9 by the false security verdict.
- **SC-003**: A person unfamiliar with the setup identifies the stage that stopped a change, and opens its failure details, within 1 minute from a single screen.
- **SC-004**: For merged PRs with no intervening changes, the PR gate result and deploy gate result agree ≥ 95% of the time.
- **SC-005**: ≤ 10% of visible delivery history consists of runs that performed no work. The baseline is 60–100% per process.
- **SC-006**: Every check shown in the single view has a matching catalog entry (100% coverage), and its observed behavior matches its documented category.
- **SC-007**: Time from merge to live site for a content-only change is no longer than today's successful deploys, because duplicate builds and duplicate test runs are removed.

## Assumptions

- There is a single maintainer and operator. Access control and multi-team ownership are out of scope.
- The delivery system stays on the existing self-hosted Jenkins. This spec reorganizes and adds visibility; it does not migrate platforms.
- The repository's hosting plan cannot enforce required status checks on PRs. PR gates stay informative there, and the deploy is the enforcement point. The single view is the place to see PR readiness.
- The existing alerting channel (Grafana email alerts) can receive Monitoring-class failures.
- The content-pipeline unit tests guard automation code that does not ship with the website. They stay Blocking for changes that touch that automation. For all other changes they are Advisory, and their failures are still reported and emailed on main (see research.md D4). Their current failures are real defects, fixed outside this feature.
- The security posture does not weaken. Secrets, high-severity dependencies, and the curated infrastructure rule list stay Blocking (FR-004). Only misclassified or falsely failing checks change.
- Scope covers the blogLosAngeles delivery processes (deploy, security gate, live security, SEO crawl, smoke tests, infrastructure) and the shared CI pieces they rely on. Other repositories may adopt the pattern later but are out of scope.
