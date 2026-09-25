// Returns 'true' (and marks the build NOT_BUILT) when a push-triggered build's
// head commit was made by jenkins-bot or carries [skip ci]. Use as the first stage:
//   stage('Gate') { steps { script { env.SKIP = skipIfBotCommit() } } }
// and guard later stages with  when { expression { env.SKIP != 'true' } }
def call() {
    if (!(triggeredBy() in ['scm', 'indexing'])) { return 'false' }
    def email = sh(script: 'git log -1 --format=%ae', returnStdout: true).trim()
    def msg = sh(script: 'git log -1 --format=%B', returnStdout: true)
    if (email == botEmail() || msg.contains('[skip ci]')) {
        currentBuild.result = 'NOT_BUILT'
        currentBuild.description = 'skipped: bot commit / [skip ci]'
        return 'true'
    }
    return 'false'
}
