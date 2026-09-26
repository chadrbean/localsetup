@Library('ci') _

// agent/feature-worker (jenkins/casc/github/seed.groovy; started by agent/feature-dispatcher,
// or by hand for a test run). Takes one GitHub issue from "In progress" to "Done"
// (names from config.json statuses):
//   specify -> plan -> checklist -> tasks -> analyze -> implement [-> converge -> implement]
//   -> sync (merge latest main; Claude resolves conflicts)
//   -> validate (repo's ci/jenkins/agent-validate.groovy, up to fixAttempts Claude fix passes)
//   -> push branch + open PR (Closes #issue) -> wait for any PR checks -> merge -> card to Done
//      (autoMerge: false -> card to In review instead).
// Any failure -> card to Blocked, WIP branch pushed, issue comment + email; the dispatcher
// moves on to the next Ready card. Each stage is one headless `claude -p` (claudeStep) that
// never asks questions: decisions land in the spec's "## Assumptions", which the PR shows.
// Live visibility: Jenkins stage view, the card's Stage/Run fields, one progress comment on
// the issue (edited in place). Transcripts: build artifacts .agent/logs/*.jsonl.
// Settings: jenkins/shared-library/resources/agent/config.json. Runbook: docs/AGENT-PIPELINE.md

CFG = null          // agentConfig(REPO)
ISSUE = null        // gh issue view JSON
PROGRESS = []       // progress comment lines
COMMENT_ID = null   // issue comment edited in place
STAGE = 'prepare'   // current stage, for the failure message and the board
BRANCH = null       // feature branch spec-kit created
TOTAL_COST = 0.0

// Card fields (skipped for manual runs without ITEM_ID; never fails the build).
void board(List args) {
    if (params.ITEM_ID) { projectBoard(['set', params.ITEM_ID] + args, true) }
}

// Append a line to the single progress comment on the issue (best effort).
void progress(String line) {
    PROGRESS << line
    writeFile file: '.agent/progress.md', text: "### 🤖 Agent pipeline — [run #${env.BUILD_NUMBER}](${env.BUILD_URL})\n\n" +
        PROGRESS.collect { "- ${it}" }.join('\n') + '\n'
    try {
        withGitHubToken {
            if (COMMENT_ID) {
                sh "gh api -X PATCH 'repos/${params.REPO}/issues/comments/${COMMENT_ID}' -F body=@.agent/progress.md --silent"
            } else {
                COMMENT_ID = sh(returnStdout: true, script:
                    "gh api 'repos/${params.REPO}/issues/${params.ISSUE}/comments' -F body=@.agent/progress.md --jq .id").trim()
            }
        }
    } catch (hudson.AbortException e) {
        echo "progress: WARNING could not update the issue comment (${e.message})"
    }
}

// First existing skill/command name in the target repo, as a slash command.
String skill(List names) {
    def n = names.find { fileExists("repo/.claude/skills/${it}/SKILL.md") || fileExists("repo/.claude/commands/${it}.md") }
    if (!n) { error("repo has none of the skills ${names} — is spec-kit installed with the Claude integration?") }
    return "/${n}"
}

// Short repo name for build names: blogLosAngeles -> blog, zca-accounting -> zca.
String shortRepo() {
    def n = params.REPO.tokenize('/')[-1]
    def abbrev = [blogLosAngeles: 'blog', 'zca-accounting': 'zca'][n]
    return abbrev ?: n
}

// Build description = what is happening to which feature, e.g. "plan ▸ Better Parsing Of Events…".
void describe(String state) {
    currentBuild.description = ISSUE ? "${state} ▸ ${ISSUE.title}" : state
}

// One Claude stage: board Stage field, claudeStep, progress line. Returns the final message.
String runStage(String id, String prompt) {
    STAGE = id
    describe(id)
    board(['--stage', id == 'sync' ? 'fix' : id.replaceAll('-.*', '')])   // Stage options: config.json stages
    def r = claudeStep(stage: id, prompt: prompt, image: CFG.image, model: CFG.model,
                       maxTurns: CFG.maxTurns, minutes: CFG.stageMinutes)
    TOTAL_COST += (r.cost ?: 0) as double
    def first = r.text.readLines().find { it.trim() } ?: ''
    progress("✅ **${id}** — ${first.length() > 160 ? first.substring(0, 160) + '…' : first}")
    return r.text
}

// Value of a machine-readable last line like CRITICAL_REMAINING=2 (null if absent).
Integer lastLineInt(String text, String key) {
    def m = text.readLines().reverse().find { it.trim().startsWith("${key}=") }
    def digits = m ? m.trim().substring(key.length() + 1).replaceAll('[^0-9]', '') : ''
    return digits ? Integer.parseInt(digits) : null
}

// Feature dir from .specify/feature.json, relative to the repo root.
String featureDir() {
    if (!fileExists('repo/.specify/feature.json')) { return '' }
    def d = (readJSON(file: 'repo/.specify/feature.json').feature_directory ?: '').toString()
    def root = "${env.WORKSPACE}/repo/"
    return d.startsWith(root) ? d.substring(root.length()) : d
}

// Push the current HEAD as the feature branch. A branch left by an earlier (Blocked) run of
// the same spec number gets a -r<build> suffix instead of a force-push.
String pushBranch() {
    def name = BRANCH
    withGitHubToken {
        def auth = 'AUTHORIZATION: basic $(printf "x-access-token:%s" "$GH_TOKEN" | base64 -w0)'
        def url = "https://github.com/${params.REPO}.git"
        dir('repo') {
            def exists = sh(returnStatus: true, script: "git -c http.extraHeader=\"${auth}\" ls-remote --exit-code --heads '${url}' '${name}' >/dev/null")
            if (exists == 0) { name = "${name}-r${env.BUILD_NUMBER}" }
            sh "git -c http.extraHeader=\"${auth}\" push '${url}' 'HEAD:refs/heads/${name}'"
        }
    }
    return name
}

// Refresh origin/main in the checkout (the job's checkout credentials aren't kept for plain git).
void fetchMain() {
    withGitHubToken {
        def auth = 'AUTHORIZATION: basic $(printf "x-access-token:%s" "$GH_TOKEN" | base64 -w0)'
        sh "git -C repo -c http.extraHeader=\"${auth}\" fetch -q 'https://github.com/${params.REPO}.git' '+refs/heads/main:refs/remotes/origin/main'"
    }
}

// Wait for the PR's GitHub checks, if the repo reports any. `gh pr checks` exits 0 = all passed,
// 8 = pending, 1 = failed or no checks at all (then the Validate gate was the only gate).
void waitForChecks(String pr) {
    sleep(time: 30, unit: 'SECONDS')   // let webhooks register the checks
    def deadline = System.currentTimeMillis() + ((CFG.checksMinutes ?: 60) as long) * 60000L
    while (true) {
        def rc = 0
        def out = ''
        withGitHubToken {
            rc = sh(returnStatus: true, script: "gh pr checks '${pr}' > .agent/checks.txt 2>&1")
            out = readFile('.agent/checks.txt').trim()
        }
        if (rc == 0) { progress('✅ **PR checks** passed'); return }
        if (out.contains('no checks reported')) { echo 'PR has no GitHub checks; the Validate gate was the gate'; return }
        if (rc != 8) { error("PR checks failed:\n${out}") }
        if (System.currentTimeMillis() > deadline) { error("PR checks still pending after ${CFG.checksMinutes} min:\n${out}") }
        sleep(time: 60, unit: 'SECONDS')
    }
}

void commitAll(String message) {
    dir('repo') {
        sh """
          git add -A
          git diff --cached --quiet || git -c user.name=jenkins-agent -c user.email=jenkins-agent@chadrbean.com \\
            commit -q -m '${message.replace("'", "")}'
        """
    }
}

pipeline {
    agent any

    parameters {
        string(name: 'REPO', defaultValue: '', description: 'owner/repo (must be allowlisted in resources/agent/config.json)')
        string(name: 'ISSUE', defaultValue: '', description: 'Issue number in REPO')
        string(name: 'ITEM_ID', defaultValue: '', description: 'Project item id (set by the dispatcher; blank = manual run, no board updates)')
    }

    options {
        timestamps()
        timeout(time: 8, unit: 'HOURS')
        skipDefaultCheckout()
        buildDiscarder(logRotator(numToKeepStr: '60', artifactNumToKeepStr: '30'))
    }

    environment {
        AGENT_DIR = "${WORKSPACE}/.agent"
        // Under the checkout (git-excluded): the gate's containers mount only the repo dir.
        AGENT_VALIDATE_DIR = "${WORKSPACE}/repo/.agent-validate"
        GITHUB_STEP_SUMMARY = "${WORKSPACE}/summary.md"
    }

    stages {
        stage('Prepare') {
            steps {
                script {
                    if (!params.REPO || !params.ISSUE) { error('REPO and ISSUE are required') }
                    cleanWs()
                    CFG = agentConfig(params.REPO)
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${params.REPO.tokenize('/')[1]}#${params.ISSUE}"
                    sh 'mkdir -p .agent/logs .agent/prompts'
                    board(['--run', env.BUILD_URL])
                    dir('repo') {
                        checkout scmGit(branches: [[name: 'main']],
                                        userRemoteConfigs: [[url: "https://github.com/${CFG.repo}.git", credentialsId: 'github-app']])
                        sh 'git checkout -q -B main && echo .agent-validate/ >> .git/info/exclude'
                    }
                    withGitHubToken {
                        sh "gh issue view '${params.ISSUE}' --repo '${CFG.repo}' --json number,title,body,url,labels > .agent/issue.json"
                    }
                    ISSUE = readJSON(file: '.agent/issue.json')
                    writeFile file: '.agent/issue.md', text: "# ${ISSUE.title}\n\n${ISSUE.body ?: ''}\n\nSource: ${ISSUE.url}\n"
                    // Run list shows "#4 blog#226 · Better Parsing Of Events…"; description tracks the stage.
                    def t = ISSUE.title.length() > 60 ? ISSUE.title.substring(0, 60).trim() + '…' : ISSUE.title
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${shortRepo()}#${params.ISSUE} · ${t}"
                    describe('prepare')
                    addSummary icon: 'symbol-document-text-outline plugin-ionicons-api',
                               text: "Issue ${CFG.repo}#${params.ISSUE}: ${ISSUE.title}", link: ISSUE.url
                    progress("🚀 picked up — image `${CFG.image}`, model `${CFG.model}`")
                }
            }
        }

        stage('Specify') {
            steps {
                script {
                    runStage('specify', """${skill(['speckit-companion-specify', 'speckit-specify'])} ${ISSUE.title}

${ISSUE.body ?: ''}

(Feature request: GitHub issue ${CFG.repo}#${params.ISSUE}, ${ISSUE.url}. A copy is at ../.agent/issue.md.)""")
                    BRANCH = sh(returnStdout: true, script: 'git -C repo rev-parse --abbrev-ref HEAD').trim()
                    if (BRANCH in ['main', 'master', 'HEAD']) {
                        BRANCH = "feat/issue-${params.ISSUE}"
                        sh "git -C repo checkout -q -b '${BRANCH}'"
                    }
                    if (!featureDir()) { error('specify finished but .specify/feature.json names no feature directory') }
                    progress("🌿 branch `${BRANCH}`, spec `${featureDir()}`")
                    addSummary icon: 'symbol-git-branch-outline plugin-ionicons-api',
                               text: "Branch ${BRANCH} · spec ${featureDir()}"
                }
            }
        }

        stage('Plan') {
            steps { script { runStage('plan', skill(['speckit-companion-plan', 'speckit-plan'])) } }
        }

        stage('Checklist') {
            steps {
                script {
                    runStage('checklist', """${skill(['speckit-checklist'])} Choose the checklist domains yourself from the spec and plan (for example ux, api, security, data, performance): at least one, at most three.

Then evaluate every generated item against the spec and plan. Where an item fails, fix the spec or plan and mark the item [x]. Leave an item unchecked only if it cannot be resolved without the product owner, and add a one-line note to it.""")
                }
            }
        }

        stage('Tasks') {
            steps { script { runStage('tasks', skill(['speckit-companion-tasks', 'speckit-tasks'])) } }
        }

        stage('Analyze') {
            steps {
                script {
                    def out = runStage('analyze', """${skill(['speckit-analyze'])}

After the report: analyze is read-only on its own, but in this pipeline you are authorized to apply its remediation. Fix every CRITICAL and HIGH finding by editing the spec, plan and tasks directly, then re-check them.
The very last line of your reply must be exactly `CRITICAL_REMAINING=<n>`, where n is the number of CRITICAL findings still open.""")
                    def n = lastLineInt(out, 'CRITICAL_REMAINING')
                    if (n == null) {
                        echo 'analyze: no CRITICAL_REMAINING line; continuing'
                    } else if (n > (CFG.maxCriticalFindings as int)) {
                        error("analyze: ${n} CRITICAL finding(s) remain after remediation")
                    }
                }
            }
        }

        stage('Implement') {
            steps {
                script {
                    def implement = skill(['speckit-companion-implement', 'speckit-implement'])
                    runStage('implement', implement)
                    def hasConverge = fileExists('repo/.claude/skills/speckit-converge/SKILL.md')
                    if (CFG.converge && hasConverge) {
                        def out = runStage('converge', """/speckit-converge

The very last line of your reply must be exactly `NEW_TASKS=<n>`, where n is the number of tasks you appended to tasks.md.""")
                        if ((lastLineInt(out, 'NEW_TASKS') ?: 0) > 0) { runStage('implement-2', implement) }
                    }
                    commitAll("feat: implement #${params.ISSUE} (agent pipeline)")
                }
            }
        }

        // Merge the latest main before the gate, so the gate tests what will actually land and
        // conflicts are fixed now, not after the PR has waited. Claude resolves any conflicts.
        stage('Sync') {
            steps {
                script {
                    STAGE = 'sync'
                    describe('sync')
                    fetchMain()
                    def behind = sh(returnStdout: true, script: 'git -C repo rev-list --count HEAD..origin/main').trim()
                    if (behind == '0') {
                        echo 'branch already contains origin/main'
                    } else {
                        board(['--stage', 'fix'])
                        def rc = sh(returnStatus: true, script: 'git -C repo -c user.name=jenkins-agent -c user.email=jenkins-agent@chadrbean.com merge --no-edit -q origin/main')
                        if (rc == 0) {
                            progress("🔀 **sync** — merged ${behind} new commit(s) from main cleanly")
                        } else {
                            def files = sh(returnStdout: true, script: 'git -C repo diff --name-only --diff-filter=U').trim().readLines()
                            if (!files) { error("git merge origin/main failed without conflicts (rc ${rc})") }
                            progress("🔀 **sync** — main moved (${behind} commits); resolving conflicts in ${files.collect { '`' + it + '`' }.join(', ')}")
                            runStage('sync', """main has moved on since this feature branch started, and `git merge origin/main` is in progress with conflicts in:
${files.collect { '- ' + it }.join('\n')}

Resolve every conflict so that BOTH sides' intent survives: main's changes (read `git log --oneline HEAD..origin/main` and the relevant specs/ they reference) and this feature's (its spec is `${featureDir()}`). Where both sides add entries to a catalog, registry or list, keep both and keep ids unique. Don't drop main's changes to make the feature simpler. Remove every conflict marker, `git add` the files, and finish with `git commit --no-edit`. Do not rebase, reset or abort the merge.""")
                            def left = sh(returnStdout: true, script: 'git -C repo diff --name-only --diff-filter=U; git -C repo grep -lE "^(<<<<<<<|>>>>>>>) " || true').trim()
                            if (left) { error("sync: conflicts left after resolution: ${left}") }
                            if (fileExists('repo/.git/MERGE_HEAD')) { commitAll("Merge origin/main into ${BRANCH} (agent pipeline)") }
                        }
                    }
                }
            }
        }

        stage('Validate') {
            steps {
                script {
                    STAGE = 'validate'
                    describe('validate')
                    board(['--stage', 'validate'])
                    // The validation script comes from main, never from the agent's branch, so
                    // the code under test can't rewrite its own gate.
                    def vs = sh(returnStatus: true, script: 'git -C repo show origin/main:ci/jenkins/agent-validate.groovy > .agent/agent-validate.groovy')
                    if (vs != 0) { error("${CFG.repo} has no ci/jenkins/agent-validate.groovy on main — see docs/AGENT-PIPELINE.md § Onboarding") }
                    def validate = load '.agent/agent-validate.groovy'
                    def attempts = CFG.fixAttempts as int
                    boolean passed = false
                    for (int i = 0; i <= attempts && !passed; i++) {
                        sh 'rm -rf repo/.agent-validate && mkdir -p repo/.agent-validate'
                        try {
                            dir('repo') { validate.validate(CFG) }
                            passed = true
                            progress(i == 0 ? '✅ **validate** — all checks passed' : "✅ **validate** — passed after ${i} fix pass(es)")
                        } catch (hudson.AbortException e) {
                            def failed = fileExists('repo/.agent-validate/FAILED') ? readFile('repo/.agent-validate/FAILED').readLines().join(', ') : 'unknown'
                            progress("⚠️ **validate** attempt ${i + 1} failed: ${failed}")
                            if (i == attempts) { error("validation failed after ${attempts} fix pass(es): ${failed}") }
                            runStage("fix-${i + 1}", """Validation of this feature failed (attempt ${i + 1} of ${attempts + 1}). Failed checks: ${failed}.
Each failed check's full output is in .agent-validate/<check>.log, and the exact command it ran is in .agent-validate/<check>.sh (both in this checkout, git-ignored).

Find the root cause and fix the implementation. Re-run the failing commands yourself where the tools exist in this container. Do not weaken, skip or delete tests or gates. If a test is wrong for the new spec, fix the test and record why in the spec's Assumptions. Commit when done.""")
                            commitAll("fix: validation pass ${i + 1} for #${params.ISSUE} (agent pipeline)")
                        }
                    }
                }
            }
        }

        stage('Publish') {
            steps {
                script {
                    STAGE = 'publish'
                    describe('publish')
                    board(['--stage', 'publish'])
                    commitAll("chore: agent pipeline leftovers for #${params.ISSUE}")
                    def head = pushBranch()
                    def fdir = featureDir()
                    def assumptions = sh(returnStdout: true, script: """
                        f=\$(ls repo/${fdir}/*.spec.md repo/${fdir}/spec.md 2>/dev/null | head -1)
                        [ -n "\$f" ] && awk '/^## (Assumptions|Open checklist items)/{p=1} /^## / && !/^## (Assumptions|Open checklist items)/{p=0} p' "\$f" || true
                    """).trim()
                    writeFile file: '.agent/pr.md', text: """Closes #${params.ISSUE}

Built unattended by the agent pipeline: [run #${env.BUILD_NUMBER}](${env.BUILD_URL}) (transcripts under Build Artifacts → `.agent/logs`). Spec: `${fdir}`.

${assumptions ?: '## Assumptions\n\n_None recorded._'}

## Pipeline
${PROGRESS.collect { "- ${it}" }.join('\n')}

Claude cost: \$${String.format('%.2f', TOTAL_COST)}
"""
                    def pr = ''
                    withGitHubToken {
                        pr = sh(returnStdout: true, script: """
                            gh pr create --repo '${CFG.repo}' --base main --head '${head}' \\
                              --title '${ISSUE.title.replace("'", "")}' --body-file .agent/pr.md
                        """).trim()
                    }
                    def prNum = pr.tokenize('/')[-1]
                    writeFile file: 'summary.md', text: "# ${CFG.repo}#${params.ISSUE} → ${pr}\n\n" + readFile('.agent/pr.md')
                    addSummary icon: 'symbol-git-pull-request-outline plugin-ionicons-api',
                               text: "Pull request #${prNum}", link: pr
                    if (CFG.autoMerge) {
                        // Gate passed on code that already contains main: merge now, so the next
                        // card starts from it and branches don't pile up and conflict.
                        STAGE = 'merge'
                        describe('merge')
                        waitForChecks(pr)
                        withGitHubToken {
                            sh "gh pr merge '${pr}' --${CFG.mergeMethod ?: 'squash'} --delete-branch"
                        }
                        board(['--status', 'done', '--clear-stage'])
                        progress("🎉 merged: ${pr}")
                        currentBuild.description = "✅ ${ISSUE.title} → merged PR #${prNum}"
                    } else {
                        board(['--status', 'review', '--clear-stage'])
                        progress("🔎 ready for review: ${pr}")
                        currentBuild.description = "✅ ${ISSUE.title} → PR #${prNum}"
                    }
                }
            }
        }
    }

    post {
        unsuccessful {
            script {
                if (!ISSUE && !params.ITEM_ID) { return }   // manual run that failed before reading the issue
                def wip = ''
                if (BRANCH) {
                    try {
                        commitAll("wip: agent pipeline stopped at ${STAGE} for #${params.ISSUE}")
                        wip = " WIP branch `${pushBranch()}`."
                    } catch (hudson.AbortException e) {
                        echo "could not push the WIP branch: ${e.message}"
                    }
                }
                def title = ISSUE ? ISSUE.title : "${CFG?.repo ?: params.REPO}#${params.ISSUE}"
                if (currentBuild.result == 'ABORTED') {
                    // Restart or manual abort: not the feature's fault, just queue it again.
                    board(['--status', 'ready', '--clear-stage'])
                    currentBuild.description = "⏹ aborted at ${STAGE}: ${title}"
                    if (ISSUE) { progress("⏹ **${STAGE}** aborted.${wip} Card returned to Ready.") }
                } else if (env.AGENT_FAILURE_KIND == 'infra' || STAGE == 'prepare') {
                    // Credentials, limits, network, checkout: every card would fail the same way.
                    // Put this one back and pause the dispatcher until its health check passes.
                    def reason = env.AGENT_FAILURE_REASON ?: "${STAGE} failed (checkout, issue or board access)"
                    board(['--status', 'ready', '--clear-stage'])
                    def newly = agentPause.pause(reason, [repo: params.REPO, issue: params.ISSUE])
                    currentBuild.description = "⏸ paused: ${reason}"
                    if (ISSUE) { progress("⏸ **${STAGE}** hit an infrastructure problem (${reason}).${wip} Card returned to Ready; the pipeline is paused and will retry automatically.") }
                    if (newly) {
                        notifyFailure(subject: "[agent] pipeline PAUSED: ${reason.length() > 80 ? reason.substring(0, 80) : reason}",
                                      body: "Worker ${env.BUILD_URL} stopped on an infrastructure problem, not the feature:\n\n${reason}\n\n" +
                                            "${title} was returned to Ready. The dispatcher claims nothing until its health check passes, " +
                                            "then resumes on its own. Force-resume: delete \$JENKINS_HOME/agent-pipeline/paused.json. " +
                                            "See docs/AGENT-PIPELINE.md § Pause.")
                    }
                } else {
                    board(['--status', 'blocked'])
                    currentBuild.description = "❌ ${STAGE}: ${title}"
                    progress("❌ **${STAGE}** failed — [console](${env.BUILD_URL}console).${wip} Fix or edit the issue, then move the card back to Ready.")
                    notifyFailure()
                }
            }
        }
        always {
            archiveArtifacts artifacts: '.agent/**, repo/.agent-validate/**', excludes: '.agent/bin/**', allowEmptyArchive: true
            stepSummary()
        }
    }
}
