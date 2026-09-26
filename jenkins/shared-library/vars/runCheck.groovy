// runCheck(id: 'internal-links')                        — command from the repo's ci/checks.yml
// runCheck(id: 'site-build', script: 'cd site && hugo') — explicit shell overrides the catalog
//
// Runs ONE catalogued check and turns its exit code into a stage result using the check's
// category in ci/checks.yml, so what the catalog says and what the pipeline does cannot drift.
// Exit codes: 0 pass, 1 findings, 2 tool error, 3 inconclusive (external source down), 4 n/a.
//
//                0        1          2          3             4
//   blocking     SUCCESS  FAILURE    FAILURE    UNSTABLE      SUCCESS
//   advisory     SUCCESS  UNSTABLE   UNSTABLE   UNSTABLE      SUCCESS
//   monitoring   SUCCESS  FAILURE    FAILURE    FAILURE       SUCCESS   (site-health jobs only)
//
// A `scope`d blocking check is advisory unless this push/PR touches one of its paths (always
// advisory on cron/manual). A FAILURE never aborts the stage: sibling checks still run, and the
// first blocking failure is named on the build page ("Blocked by <id>"). A manual main build
// with OVERRIDE_REASON downgrades blocking failures to UNSTABLE and records who and why.
// Results collect in env.CHECK_RESULTS for checkReport(). Returns the verdict string.
// Contract: localsetup specs/001-blog-pipeline-visibility/contracts/check-result-contract.md
def call(Map args) {
    def catalogPath = args.catalog ?: 'ci/checks.yml'
    def entry = (readYaml(file: catalogPath).checks ?: []).find { it.id == args.id }
    if (!entry) {
        error("runCheck: '${args.id}' is not in ${catalogPath}; every check must be catalogued (docs/ci-gates.md)")
    }
    def category = effectiveCategory(entry)
    def cmd = args.script ?: entry.command ?: "python3 scripts/smoketests/check_${args.id.replace('-', '_')}.py"

    echo "▶ ${args.id} [${category}] ${entry.threshold}"
    int rc = sh(returnStatus: true, script: cmd)
    def verdict = [0: 'passed', 1: 'failed', 2: 'errored', 3: 'inconclusive', 4: 'n/a'][rc] ?: 'errored'
    def result = resultFor(category, verdict)
    def note = ''

    if (result == 'FAILURE' && category == 'blocking' && overrideActive()) {
        result = 'UNSTABLE'
        note = "OVERRIDDEN: ${params.OVERRIDE_REASON.trim()}"
        env.OVERRIDDEN_CHECKS = ((env.OVERRIDDEN_CHECKS ?: '') + " ${args.id}").trim()
        addErrorBadge(text: "OVERRIDE ${args.id}: ${params.OVERRIDE_REASON.trim()} (${overrideUser()})")
    }

    env.CHECK_RESULTS = (env.CHECK_RESULTS ?: '') +
        "| `${args.id}` | ${entry.stage} | ${category} | ${verdict} (exit ${rc}) | ${result} ${note} |\n"

    def msg = "${args.id}: ${verdict} (exit ${rc}, ${category}) — ${entry.threshold}"
    if (result == 'UNSTABLE') {
        unstable(msg)
    } else if (result == 'FAILURE') {
        if (category == 'blocking' && !env.BLOCKED_BY) {
            env.BLOCKED_BY = args.id
            addErrorBadge(text: "Blocked by ${args.id} (${entry.stage})", link: env.BUILD_URL)
            currentBuild.description = "Blocked by ${args.id} (${entry.stage}): ${verdict}"
        }
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') { error(msg) }
    } else {
        echo "✔ ${msg}"
    }
    return verdict
}

private String resultFor(String category, String verdict) {
    if (verdict in ['passed', 'n/a']) { return 'SUCCESS' }
    if (category == 'advisory') { return 'UNSTABLE' }
    if (category == 'monitoring') { return 'FAILURE' }
    return verdict == 'inconclusive' ? 'UNSTABLE' : 'FAILURE'
}

private String effectiveCategory(Map entry) {
    if (entry.category != 'blocking' || !entry.scope) { return entry.category }
    if (!(triggeredBy() in ['scm', 'indexing'])) { return 'advisory' }
    if (env.CI_CHANGED_FILES == null) {
        def files = changedFiles()
        env.CI_CHANGED_FILES = files == null ? '__unknown__' : files.join('\n')
    }
    if (env.CI_CHANGED_FILES == '__unknown__') { return 'blocking' }
    def touched = env.CI_CHANGED_FILES.split('\n').any { f -> entry.scope.any { p -> f.startsWith(p) } }
    return touched ? 'blocking' : 'advisory'
}

private boolean overrideActive() {
    def reason = params.OVERRIDE_REASON?.trim()
    if (!reason) { return false }
    if (triggeredBy() == 'manual' && env.BRANCH_NAME == 'main') { return true }
    echo 'OVERRIDE_REASON ignored: overrides apply to manual builds of main only'
    return false
}

private String overrideUser() {
    def causes = currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause')
    return causes ? (causes[0].userId ?: causes[0].userName) : 'unknown'
}
