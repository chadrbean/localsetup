@Library('ci') _

// agent/feature-dispatcher (jenkins/casc/github/seed.groovy, every 5 min): the "pull"
// half of the agent feature pipeline (docs/AGENT-PIPELINE.md).
//   1. board.py claim: for each allowlisted repo with a free WIP slot, move the top Ready
//      issue (board order) to In Progress. The status flip IS the claim, so a later tick
//      never picks the same card twice.
//   2. Start agent/feature-worker for each claimed card and return (wait: false).
// Pause the pipeline: stop moving cards to Ready, or disable this job.

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
                    projectBoard(['claim', '--out', '.agent/claims.json'])
                    def claims = readJSON(file: '.agent/claims.json')
                    if (!claims) {
                        currentBuild.description = 'nothing to claim'
                        return
                    }
                    claims.each { c ->
                        build(job: 'agent/feature-worker', wait: false, parameters: [
                            string(name: 'REPO', value: c.repo),
                            string(name: 'ISSUE', value: "${c.issue}"),
                            string(name: 'ITEM_ID', value: c.itemId),
                        ])
                    }
                    currentBuild.description = claims.collect { "${it.repo.tokenize('/')[1]}#${it.issue}" }.join(', ')
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
