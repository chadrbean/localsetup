// runCatalogStage(stage: 'checks/tests')
// Runs every ci/checks.yml entry whose `stage` matches, in catalog order, each through
// runCheck — so each smoketest keeps its own category/scope and the build page names the exact
// check that blocked. Every check runs even after one fails; the stage ends with the worst result.
// Checks without a `command` run python3 scripts/smoketests/check_<id with _>.py.
def call(Map args) {
    def catalogPath = args.catalog ?: 'ci/checks.yml'
    def ids = (readYaml(file: catalogPath).checks ?: []).findAll { it.stage == args.stage }.collect { it.id }
    if (!ids) {
        error("runCatalogStage: no checks with stage '${args.stage}' in ${catalogPath}")
    }
    ids.each { id -> runCheck(id: id, catalog: catalogPath) }
}
