# Agent feature pipeline — GitHub Projects → spec-kit → Claude Code → PR

Stage features as issues on a GitHub Project board (one board per repo is fine; the dispatcher
polls every board in `config.json` → `projects`). Dragging a card to **Ready** is the only
input. From there Jenkins runs the whole spec-kit flow headless, merges the latest main in,
gates it, opens a PR and **merges it**; the card lands in **Done**. There is no human review
step (`autoMerge`, default true): quality comes from the gates (the repo's
`agent-validate.groovy`, smoketests, any GitHub PR checks), so improve those rather than
adding review. Merging every feature right away keeps branches from piling up and conflicting.
Nothing asks you questions: decisions go into the spec's `## Assumptions`, and the merged PR
shows them.

Boards in use: [#3 blogLosAngeles](https://github.com/users/chadrbean/projects/3),
[#2 ZCA Accounting](https://github.com/users/chadrbean/projects/2),
[#4 localsetup](https://github.com/users/chadrbean/projects/4) and
[#5 aws-infrastructure](https://github.com/users/chadrbean/projects/5). Status names below are theirs
(`config.json` → `statuses`).

```
Backlog ──(you)──> Ready ──(dispatcher, every 5 min, WIP/repo)──> In progress ──(worker: gate + merge)──> Done
                                                                      │ feature failure
                                                                      ├──> Blocked (issue comment + email; fix/edit, move back to Ready)
                                                                      │ infrastructure failure (token, limit, network, checkout)
                                                                      └──> back to Ready + pipeline PAUSED (see § Pause)

agent/feature-worker, one issue:
  Prepare    checkout main, read the issue, card Run = build URL
  Specify    /speckit-companion-specify <issue title + body>   (spec-kit git hook creates the branch)
  Plan       /speckit-companion-plan
  Checklist  /speckit-checklist  (domains picked by Claude; failing items fixed in spec/plan)
  Tasks      /speckit-companion-tasks
  Analyze    /speckit-analyze + apply CRITICAL/HIGH remediation; CRITICAL left > 0 -> Blocked
  Implement  /speckit-companion-implement [+ /speckit-converge -> implement again if it added tasks]
  Sync       fetch + merge origin/main; on conflicts Claude resolves them (both sides' intent kept),
             no markers may remain (board Stage shows "fix")
  Validate   repo's ci/jenkins/agent-validate.groovy (from main); on failure Claude gets the logs,
             up to fixAttempts fix passes
  Publish    push branch, gh pr create (Closes #N, Assumptions, stage log), wait for the PR's
             GitHub checks if any (checksMinutes), gh pr merge --squash --delete-branch, card -> Done
             (autoMerge false -> card -> In review; checks failing / merge refused -> Blocked, PR stays open)
```

Each stage is one `claude -p` run (`claudeStep`) in a disposable container. It skips
`/speckit-clarify` by design. Companion variants (`speckit-companion-*`) are used when the
repo has them, and plain `speckit-*` otherwise. The companion extension also gets
`unattended=true`, so its review gates record the checkpoint and continue.

## Where to watch

| What | Where |
|---|---|
| Card position + current step | Project board: Status column, **Stage** field, **Run** field (Jenkins link) |
| Step-by-step log for one feature | One progress comment on the issue, edited in place per stage |
| Live stages / console | `https://jenkins.chadrbean.com/job/agent/job/feature-worker/` (stage view). Runs are named `#<n> blog#226 · <issue title>`; the description shows `<stage> ▸ <title>`, then `✅ … → PR #N`, `❌ <stage>: …` or `⏸ paused: …`; the run page links the issue, branch/spec and PR |
| Dispatcher ticks | `…/job/agent/job/feature-dispatcher/`: `nothing to claim`, `claimed blog#226 “…”`, or `PAUSED: <reason> (N card(s) waiting)` (UNSTABLE) |
| Full Claude transcripts | Worker build → Build Artifacts → `.agent/logs/<stage>.jsonl` (+ `<stage>.md` final message); gate logs `repo/.agent-validate/<check>.log` |
| Failures | Feature: card → Blocked, issue comment with the failing stage, SES email (`notifyFailure`). Infrastructure: card → Ready, one `[agent] pipeline PAUSED` email, then `RESUMED` when healthy |
| Result | The merged PR: Assumptions + open checklist items + stage summaries + Claude cost. The issue is closed by `Closes #N`. Any GitHub checks the repo reports on the PR must pass before the merge |

## Pieces

| File | Role |
|---|---|
| `ci/jenkins/feature-dispatcher.Jenkinsfile` | Cron `H/5`. `board.py claim --dry-run` → health check (`agentPreflight`) → pause/resume → `board.py claim`, then `build agent/feature-worker` per claim (no wait) |
| `ci/jenkins/feature-worker.Jenkinsfile` | The stages above; post-failure → Blocked (feature) or Ready + pause (infrastructure) + WIP branch push |
| `jenkins/shared-library/resources/agent/config.json` | Project number, field/status names, **repo allowlist**, per-repo `image`/`wip`/`model`/`maxTurns`/`stageMinutes`/`fixAttempts`/`converge`/`maxCriticalFindings` |
| `jenkins/shared-library/resources/agent/board.py` | Projects v2 GraphQL: `setup`, `claim`, `set`, `list` (stdlib Python) |
| `jenkins/shared-library/resources/agent/headless-prompt.md` | Appended system prompt: never ask, record Assumptions, no push/deploy/secrets, don't weaken gates |
| `jenkins/shared-library/vars/{claudeStep,projectBoard,agentConfig,agentCheck}.groovy` | Shared steps (`claudeStep` also classifies infrastructure failures) |
| `jenkins/shared-library/vars/{agentPause,agentPreflight}.groovy` | Circuit breaker: pause file + one-turn `claude -p` health check (§ Pause) |
| `jenkins/images/ci-claude/Containerfile` | Claude Code (pinned) on top of a repo toolchain image (`BASE` build-arg) |
| `jenkins/agent-templates/agent-validate.groovy` | Template validation gate for onboarding |
| `scripts/agent_onboard.sh` | Onboard a repo (contract check + scaffold + allowlist + project link) |

The jobs are seeded as `agent/feature-dispatcher` and `agent/feature-worker`
(`jenkins/casc/github/seed.groovy`) and run from this repo's `main`. They are not per-repo
multibranch jobs, so zca-accounting's manual-only CI rule is untouched.

## Security model

- Claude runs as container root (= host uid 1000 under rootless podman) with
  `--permission-mode bypassPermissions`, `IS_SANDBOX=1`. The container gets the workspace
  mount and `CLAUDE_CODE_OAUTH_TOKEN` only: no podman socket, no AWS roles, no GitHub token.
  Pushing, PRs and board updates happen in the pipeline, outside Claude's container.
- The validation gate is loaded from `origin/main`, never from the agent's branch, so the code
  under test can't rewrite its own gate. Changing the gate is a normal reviewed PR.
- Only allowlisted repos (`config.json` → `repos`) are ever checked out. A card from any other
  repo is skipped.
- Agent commits are authored by `jenkins-agent@chadrbean.com`, not `jenkins-bot`, so
  `skipIfBotCommit()` doesn't skip the repo's own PR checks, which act as a second, independent gate.
- Nothing deploys. Deploy jobs still run only on your merge to main.

## One-time setup

1. **Boards**
   - Each board is listed in `config.json` → `projects`, keyed by `owner` and `number`. The number is
     N in `github.com/users/<owner>/projects/N`. List your boards with `gh project list --owner chadrbean`.
     Today: #3 blogLosAngeles, #2 ZCA Accounting, #4 localsetup, #5 aws-infrastructure.
   - Each board's Status needs these options: `Backlog`, `Ready`, `In progress`, `Blocked`,
     `In review`, `Done`, spelled as in `config.json` → `statuses`.
     - The GitHub "Board" template has every one except **Blocked**. Add Blocked in the UI with
       "+" at the right of the columns, or in Settings → Status.
     - Don't add it through the API. `updateProjectV2Field` replaces the whole option list and can
       clear every card's Status.
   - Then run, from this repo:
     ```bash
     gh auth refresh -s project
     GH_TOKEN=$(gh auth token) python3 jenkins/shared-library/resources/agent/board.py \
       --config jenkins/shared-library/resources/agent/config.json setup
     ```
     This creates the **Stage** (single select) and **Run** (text) fields and checks the Status options.
2. **Tokens** in `jenkins/.env`, then `podman-compose up -d` in `jenkins/` to reload JCasC.
   `scripts/agent_secrets.sh` does both keys interactively: it prompts without echoing, checks
   the PAT's scopes and the Claude token (a live `claude -p` in `ci-claude`), and writes `.env`
   with mode 600.
   - `AGENT_CLAUDE_OAUTH_TOKEN`: `claude setup-token` (subscription). To use API billing instead, bind an `ANTHROPIC_API_KEY` credential in `claudeStep`.
   - `AGENT_GH_PROJECT_PAT`: classic PAT, scopes `project` + `repo`. GitHub App tokens and fine-grained PATs can't write user-owned Projects v2.
3. **Images** (local, not pushed):
   ```bash
   podman build -t localhost/ci-claude:1 jenkins/images/ci-claude
   podman build -t localhost/ci-claude-hugo:1 --build-arg BASE=localhost/ci-hugo:1 jenkins/images/ci-claude
   ```
4. **GitHub App** `chadrbean-jenkins`: needs Contents, Issues, Pull requests = read/write on each onboarded repo.
5. Merge this to `main`, then restart Jenkins (or reload JCasC) so the seed creates `agent/*`.
6. **Smoke test.** Run `agent/feature-worker` by hand with `REPO`, `ISSUE` and an empty `ITEM_ID` (no board updates) on a small issue. After that works, put a card in Ready and let the dispatcher take it.

## Onboarding a repo

A repo works with the pipeline when it has:

| Requirement | Why |
|---|---|
| spec-kit with the Claude integration (`.specify/`, `.claude/skills/speckit-*`), ideally the `git` + `companion` extensions | The stages call these skills. The git extension's `before_specify` hook creates the feature branch |
| A filled-in `.specify/memory/constitution.md` | What Claude decides by instead of asking you. Write it once with `/speckit-constitution` (interactive) |
| `ci/jenkins/agent-validate.groovy` on main | The repo's done-gate: build/test/lint via `agentCheck(...)` in the repo's CI images. It's called with the cwd at the repo root. Keep container mounts at that level (docker `inside` mounts only the current dir) |
| `CLAUDE.md` (can just `@AGENTS.md`) | spec-kit's `context_file`; project rules for Claude |
| Entry in `config.json` → `repos` (+ `image` if it needs a special toolchain) | Allowlist + settings |
| Repo linked to the Project, GitHub App installed | Issues show up on the board; checkout/push/PR |

```bash
# existing repo — checks all of the above, scaffolds what's missing, never overwrites, never commits
scripts/agent_onboard.sh chadrbean/<repo> ~/git/<repo> [image] [board-number]
# then: fill in ci/jenkins/agent-validate.groovy, commit in the repo + here, merge both
```

**New repos:** create the repo, run `specify init --here --ai claude --ai-skills`, add the git and
companion extensions, write the constitution, then run `agent_onboard.sh`. To skip the manual
part next time, keep a `chadrbean/agent-ready-template` GitHub template repo with all of that
committed and create new repos with `gh repo create <name> --template chadrbean/agent-ready-template`.

**Toolchain.** Claude runs the repo's build and tests while implementing, so its image needs the
repo's tools. Use `localhost/ci-claude:1` (Go, Node/pnpm, Python) or build a variant:
`--build-arg BASE=<the repo's CI image>`. Set the result as `image` in `config.json`.

**Poor fits** (don't allowlist, or keep them out of Ready):
- Repos without meaningful tests: "validated" would mean nothing.
- Terraform-only repos (aws-infrastructure): implementing means applying to real infrastructure.
- Repos whose tests need production credentials.

## Writing good cards

The issue title and body are the whole feature request that `/speckit-specify` sees:

- State the outcome and who it's for.
- Include acceptance examples and constraints ("no new dependencies", "reuse X").
- Say what is out of scope.

Anything you leave out, Claude decides and records under Assumptions. Keep cards
PR-sized. For something bigger, split it into several cards.

## Operating

- **Pause everything:** stop moving cards to Ready, or disable `agent/feature-dispatcher`. Re-seeding on restart re-enables it.
- **Automatic pause (circuit breaker):** a bad token, usage/rate limit, API outage or network fault would fail every card the same way, so it doesn't count against the card:
  - `claudeStep` marks a failure as *infrastructure* when the transcript has no result, when an `is_error` result mentions auth/limit/HTTP 401·403·429·5xx/network, or when its `api_retry` events show 401/403/429. A failure in Prepare (checkout, issue, board) counts too.
  - The worker pushes the WIP branch, returns the card to **Ready**, comments `⏸ paused`, and writes `$JENKINS_HOME/agent-pipeline/paused.json` (reason, time, run, repo, issue). The first pause sends one `[agent] pipeline PAUSED` email.
  - While paused, each dispatcher tick runs `agentPreflight` (one-turn `claude -p "Reply with exactly: ok"` with the pipeline's token) and claims nothing while it fails (build UNSTABLE, description `PAUSED: …`).
  - When it passes, the dispatcher deletes the file, emails `[agent] pipeline RESUMED`, and claims as usual. The card that was put back runs again from scratch.
  - Without a pause, the check runs only when a card is claimable (dry-run claim first), so an empty queue costs nothing.
  - **Check state:** `cat ~/.local/share/jenkins/data/agent-pipeline/paused.json` (`JENKINS_HOME` is mounted at the same path on the host). **Force-resume:** `rm` that file, or wait: the next healthy check clears it.
  - A feature failure (analyze CRITICAL, validation still failing, max turns) still moves the card to Blocked and the queue moves on. An aborted run (restart, manual abort) returns its card to Ready without pausing.
- **Throughput:** `wip` per repo (default 1). The controller has 4 executors, shared with CI.
- **Blocked card:** read the issue comment and the console. The WIP branch is pushed (`<branch>` or `<branch>-r<build>`). Edit the issue (add the missing detail) and move it back to Ready. The next run starts fresh from main with a new spec number.
- **Blocked at merge** (PR checks failed, or main moved again between Sync and merge and now conflicts): the PR stays open. Either fix/merge it by hand, or close it and move the card back to Ready for a fresh run.
- **Turn review back on** for a repo: `"autoMerge": false` under that repo in `config.json` (cards then stop in In review).
- **Paths that always need your merge** (`manualMergePaths`, prefixes): a PR changing any of them passes the gate, then stops in **In review** with a `✋ needs your merge` comment. Today:
  - **aws-infrastructure:** `terraform/`, `.github/workflows/`. A merge to main runs `terraform apply` on production (Jenkins `tfPlanApply` and the Actions workflow). Review the plan the terraform job posts on the PR, then merge.
  - **localsetup:** `jenkins/`, `ci/jenkins/`, `.github/`. These are the shared library, CasC, images and this pipeline itself; an unreviewed change there alters CI for every repo.
- **Card stuck in In progress** (e.g. Jenkins restarted mid-run): check the Run link. If the build is gone, move the card back to Ready.
- **Cost:** each PR body shows the Claude cost of the run. `model` and `maxTurns` are in `config.json`.
- **Test a shared-library change** before merging: a replay of `agent/feature-worker` with `@Library('ci@<branch>') _`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Dispatcher: `no 'Stage' field` / `has no option 'Blocked'` | Do one-time setup step 1 on that board |
| `set`: `item … isn't in config.json projects` | The card's board is missing from `projects`: add it (`agent_onboard.sh … <board-number>`) |
| Nothing claimed although cards are Ready | That repo is at its WIP limit: a card already sits in In progress (possibly a manual one). Move it on, or raise `wip` |
| Dispatcher: GraphQL `INSUFFICIENT_SCOPES` / `Resource not accessible` | `AGENT_GH_PROJECT_PAT` missing the `project` scope, or it's an App/fine-grained token |
| `claudeStep infrastructure failure — …` / dispatcher `PAUSED: …` | Token invalid/expired (`claude setup-token`, then `scripts/agent_secrets.sh`), usage limit, or network. See `.agent/logs/<stage>.jsonl`. It resumes by itself once the health check passes |
| Dispatcher stays `PAUSED` although the token is fixed | The Jenkins credential still holds the old value: re-run `scripts/agent_secrets.sh` and restart Jenkins (JCasC), or force-resume by deleting `paused.json` |
| `claudeStep …: error_max_turns` | Stage needed more turns: raise `maxTurns`, or split the card |
| `… has no ci/jenkins/agent-validate.groovy on main` | Onboard the repo (the gate must be merged first) |
| `analyze: n CRITICAL finding(s) remain` | Spec contradicts itself or the constitution. Refine the card, move it back to Ready |
| Skipped with `repo not in config.json allowlist` | Add the repo (`agent_onboard.sh`) and merge |
| Card claimed but no worker build | `agent/feature-worker` missing its parameters: re-run the seed (restart Jenkins) |
