// projectBoard(['claim', '--out', '.agent/claims.json'])
// projectBoard(['set', itemId, '--status', 'review', '--clear-stage'], true)
// Runs resources/agent/board.py (GitHub Projects v2 GraphQL) in the ci-claude image
// with the 'agent-gh-project-pat' credential (a GitHub App token can't reach a
// user-owned project). optional=true logs a warning instead of failing the build,
// so a board hiccup never loses an agent run. See docs/AGENT-PIPELINE.md.
def call(List args, boolean optional = false) {
    def cfg = agentConfig()
    writeFile file: '.agent/bin/board.py', text: libraryResource('agent/board.py')
    writeFile file: '.agent/bin/config.json', text: libraryResource('agent/config.json')
    def quoted = args.collect { "'" + "${it}".replace("'", "'\\''") + "'" }.join(' ')
    try {
        withCredentials([string(credentialsId: 'agent-gh-project-pat', variable: 'GH_TOKEN')]) {
            docker.image(cfg.defaults.image).inside('-u 0:0') {
                sh "python3 .agent/bin/board.py --config .agent/bin/config.json ${quoted}"
            }
        }
    } catch (hudson.AbortException e) {
        if (!optional) { throw e }
        echo "projectBoard: WARNING ${args[0]} failed (${e.message}); continuing"
    }
}
