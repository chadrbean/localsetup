# Agent feature pipeline — GitHub Projects → spec-kit → Claude Code → PR

Stage features as issues on a GitHub Project board. Dragging a card to **Ready** is the only
input. From there Jenkins runs the whole spec-kit flow headless and lands a PR in
**Review**. You merge and move the card to **Done**. Nothing asks you questions: decisions go
into the spec's `## Assumptions`, and the PR shows them.

```
Backlog ──(you)──> Ready ──(dispatcher, every 5 min, WIP/repo)──> In Progress ──(worker)──> Review ──(you)──> Done
                                                                      │ failure
                                                                      └──> Blocked (issue comment + email; fix/edit, move back to Ready)

agent/feature-worker, one issue:
  Prepare    checkout main, read the issue, card Run = build URL
  Specify    /speckit-companion-specify <issue title + body>   (spec-kit git hook creates the branch)
  Plan       /speckit-companion-plan
  Checklist  /speckit-checklist  (domains picked by Claude; failing items fixed in spec/plan)
  Tasks      /speckit-companion-tasks
  Analyze    /speckit-analyze + apply CRITICAL/HIGH remediation; CRITICAL left > 0 -> Blocked
  Implement  /speckit-companion-implement [+ /speckit-converge -> implement again if it added tasks]
  Validate   repo's ci/jenkins/agent-validate.groovy (from main); on failure Claude gets the logs,
             up to fixAttempts fix passes
  Publish    push branch, gh pr create (Closes #N, Assumptions, stage log), card -> Review
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
| Live stages / console | `https://jenkins.chadrbean.com/job/agent/job/feature-worker/` (stage view) |
| Full Claude transcripts | Worker build → Build Artifacts → `.agent/logs/<stage>.jsonl` (+ `<stage>.md` final message); gate logs `repo/.agent-validate/<check>.log` |
| Failures | Card → Blocked, issue comment with the failing stage, SES email (`notifyFailure`) |
| Result | The PR: Assumptions + open checklist items + stage summaries + Claude cost; the repo's own PR checks run on it |

## Pieces

| File | Role |
|---|---|
| `ci/jenkins/feature-dispatcher.Jenkinsfile` | Cron `H/5`. `board.py claim`, then `build agent/feature-worker` per claim (no wait) |
| `ci/jenkins/feature-worker.Jenkinsfile` | The stages above; post-failure → Blocked + WIP branch push |
| `jenkins/shared-library/resources/agent/config.json` | Project number, field/status names, **repo allowlist**, per-repo `image`/`wip`/`model`/`maxTurns`/`stageMinutes`/`fixAttempts`/`converge`/`maxCriticalFindings` |
| `jenkins/shared-library/resources/agent/board.py` | Projects v2 GraphQL: `setup`, `claim`, `set`, `list` (stdlib Python) |
| `jenkins/shared-library/resources/agent/headless-prompt.md` | Appended system prompt: never ask, record Assumptions, no push/deploy/secrets, don't weaken gates |
| `jenkins/shared-library/vars/{claudeStep,projectBoard,agentConfig,agentCheck}.groovy` | Shared steps |
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

1. **Board**
   - Create a user project (e.g. "Feature Pipeline") with the Board layout.
   - Status options, exactly: `Backlog, Ready, In Progress, Blocked, Review, Done` (Project → Settings → Status).
   - Put its number in `config.json` → `project.number`.
   - Then run, from this repo:
     ```bash
     gh auth refresh -s project
     GH_TOKEN=$(gh auth token) python3 jenkins/shared-library/resources/agent/board.py \
       --config jenkins/shared-library/resources/agent/config.json setup
     ```
     This creates the **Stage** (single select) and **Run** (text) fields and checks the Status options.
2. **Tokens** in `jenkins/.env`, then `podman-compose up -d` in `jenkins/` to reload JCasC:
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
scripts/agent_onboard.sh chadrbean/<repo> ~/git/<repo> [image]
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
- **Throughput:** `wip` per repo (default 1). The controller has 4 executors, shared with CI.
- **Blocked card:** read the issue comment and the console. The WIP branch is pushed (`<branch>` or `<branch>-r<build>`). Edit the issue (add the missing detail) and move it back to Ready. The next run starts fresh from main with a new spec number.
- **Card stuck in In Progress** (e.g. Jenkins restarted mid-run): check the Run link. If the build is gone, move the card back to Ready.
- **Cost:** each PR body shows the Claude cost of the run. `model` and `maxTurns` are in `config.json`.
- **Test a shared-library change** before merging: a replay of `agent/feature-worker` with `@Library('ci@<branch>') _`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Dispatcher: `project.number is 0` / `no 'Stage' field` | Do one-time setup step 1 |
| Dispatcher: GraphQL `INSUFFICIENT_SCOPES` / `Resource not accessible` | `AGENT_GH_PROJECT_PAT` missing the `project` scope, or it's an App/fine-grained token |
| `claudeStep …: no result in transcript` | Token invalid/expired (`claude setup-token` again), or network. See `.agent/logs/<stage>.jsonl` |
| `claudeStep …: error_max_turns` | Stage needed more turns: raise `maxTurns`, or split the card |
| `… has no ci/jenkins/agent-validate.groovy on main` | Onboard the repo (the gate must be merged first) |
| `analyze: n CRITICAL finding(s) remain` | Spec contradicts itself or the constitution. Refine the card, move it back to Ready |
| Skipped with `repo not in config.json allowlist` | Add the repo (`agent_onboard.sh`) and merge |
| Card claimed but no worker build | `agent/feature-worker` missing its parameters: re-run the seed (restart Jenkins) |
