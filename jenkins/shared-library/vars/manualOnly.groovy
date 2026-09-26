// if (!manualOnly()) { return }        stage('Prepare') { steps { script { env.RUN = manualOnly() } } }
// manualOnly(allow: ['manual'])        refuse upstream-triggered runs too
//
// Guard for pipelines that must only run when a person (or an allowed upstream job) starts them,
// e.g. zca-accounting's Constitution Principle XX. An ALLOW-list, so a new trigger kind (branch
// indexing, a webhook, a replay) is refused by default instead of slipping through. Refused runs
// end NOT_BUILT with the reason on the build page. Returns true when the run may proceed.
// Seed entries flagged ':manual' already stop branch events from starting builds; this is the
// backstop for anything that still gets through.
def call(Map a = [:]) {
    def allow = a.allow ?: ['manual', 'upstream']
    def cause = triggeredBy()
    if (cause in allow) { return true }
    currentBuild.result = 'NOT_BUILT'
    currentBuild.description = "skipped: manual-only pipeline (trigger '${cause}' not in ${allow})"
    echo "Manual-only pipeline: '${cause}'-triggered run not executed. Use \"Build with Parameters\"."
    return false
}
