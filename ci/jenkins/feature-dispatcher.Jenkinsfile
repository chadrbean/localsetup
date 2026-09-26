@Library('ci') _

// agent/feature-dispatcher (jenkins/casc/github/seed.groovy, every 5 min): the "pull"
// half of the agent feature pipeline (docs/AGENT-PIPELINE.md).
//   1. board.py claim --dry-run: what would be claimed? Nothing (and not paused) -> stop, free.
//   2. agentPreflight: one tiny headless `claude -p` with the pipeline's token. Failing ->
//      pause (agentPause, email once), claim nothing, build UNSTABLE. Passing -> clear any
//      pause (email "RESUMED").
//   3. board.py claim, across every board in config.json projects: for each allowlisted repo
//      with a free WIP slot, move the top Ready issue (board order) to In progress. The status
//      flip IS the claim, so a later tick never picks the same card twice.
//   4. Start agent/feature-worker for each claimed card and return (wait: false).
// Workers also pause the pipeline on credential/limit/network failures (claudeStep), so one
// bad token can't fail the whole Ready queue. Force-resume: delete
// $JENKINS_HOME/agent-pipeline/paused.json. Stop the pipeline: disable this job.

// "blog#226 “Better Parsing Of Events…”" for build descriptions.
String label(Map c) {
    def t = c.title ?: ''
    return "${c.repo.tokenize('/')[-1]}#${c.issue} “${t.length() > 50 ? t.substring(0, 50).trim() + '…' : t}”"
}

pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        timestamps()
        timeout(time: 10, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '100'))
    }

    stages {
        stage('Claim') {
            steps {
                script {
                    sh 'rm -rf .agent && mkdir -p .agent'
                    projectBoard(['claim', '--dry-run', '--out', '.agent/claimable.json'])
                    def waiting = readJSON(file: '.agent/claimable.json')
                    def paused = agentPause.isPaused()
                    if (!waiting && !paused) {
                        currentBuild.description = 'nothing to claim'
                        return
                    }

                    def health = agentPreflight()
                    if (!health.ok) {
                        def newly = agentPause.pause(health.reason, [source: 'dispatcher health check'])
                        currentBuild.description = "PAUSED: ${health.reason} (${waiting.size()} card(s) waiting)"
                        if (newly) {
                            notifyFailure(subject: "[agent] pipeline PAUSED: ${health.reason.length() > 80 ? health.reason.substring(0, 80) : health.reason}",
                                          body: "The agent dispatcher's health check failed:\n\n${health.reason}\n\n" +
                                                "No cards are claimed until it passes; it re-checks every 5 minutes and resumes on its own.\n" +
                                                "Waiting: ${waiting.collect { label(it) }.join(', ') ?: 'none'}\n\n${env.BUILD_URL}console\n" +
                                                "Force-resume: delete \$JENKINS_HOME/agent-pipeline/paused.json. See docs/AGENT-PIPELINE.md § Pause.")
                        }
                        unstable("agent pipeline paused: ${health.reason}")
                        return
                    }
                    if (agentPause.clear()) {
                        notifyFailure(subject: '[agent] pipeline RESUMED',
                                      body: "Health check passed; the agent dispatcher is claiming Ready cards again.\n" +
                                            "Paused since ${paused.since}: ${paused.reason}\n\n${env.BUILD_URL}console\n")
                    }

                    projectBoard(['claim', '--out', '.agent/claims.json'])
                    def claims = readJSON(file: '.agent/claims.json')
                    if (!claims) {
                        currentBuild.description = paused ? 'resumed; nothing to claim' : 'nothing to claim'
                        return
                    }
                    claims.each { c ->
                        build(job: 'agent/feature-worker', wait: false, parameters: [
                            string(name: 'REPO', value: c.repo),
                            string(name: 'ISSUE', value: "${c.issue}"),
                            string(name: 'ITEM_ID', value: c.itemId),
                        ])
                    }
                    currentBuild.description = (paused ? 'resumed; ' : '') + 'claimed ' + claims.collect { label(it) }.join(', ')
                }
            }
        }
    }

    post {
        // Every 5 min: only email on the first failure of a streak, not every tick.
        failure {
            script {
                if (currentBuild.previousBuild?.result == 'SUCCESS') { notifyFailure() }
            }
        }
    }
}
