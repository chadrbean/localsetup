// post { always { checkReport(); stepSummary() } }
// Prepends a verdict line and the per-check table collected by runCheck (env.CHECK_RESULTS) to
// summary.md, so the build-page summary (stepSummary) leads with what blocked, if anything.
def call(String file = 'summary.md') {
    if (!env.CHECK_RESULTS) { return }
    def headline = env.BLOCKED_BY ? "# Blocked by ${env.BLOCKED_BY}" :
                   env.OVERRIDDEN_CHECKS ? "# Deployed with OVERRIDE (${env.OVERRIDDEN_CHECKS})" :
                   currentBuild.currentResult == 'UNSTABLE' ? '# Passed with warnings' :
                   '# All checks passed'
    def table = "${headline}\n\n| check | stage | category | verdict | result |\n|---|---|---|---|---|\n" +
                env.CHECK_RESULTS + '\nCategories and thresholds: docs/ci-gates.md\n\n'
    def existing = fileExists(file) ? readFile(file) : ''
    writeFile file: file, text: table + existing
}
