// Circuit breaker for the agent feature pipeline (docs/AGENT-PIPELINE.md § Pause).
// One file on the controller: ${JENKINS_HOME}/agent-pipeline/paused.json. Both agent jobs run on
// the built-in node, so writeFile/readJSON on that absolute path work, and it survives restarts.
// Force-resume by deleting the file; the dispatcher also clears it once its health check passes.
//   agentPause.isPaused()           -> Map (reason, since, run, repo, issue) or null
//   agentPause.pause(reason, extra) -> true if this call newly paused the pipeline
//   agentPause.clear()              -> true if the pipeline was paused
def path() { return "${env.JENKINS_HOME}/agent-pipeline/paused.json" }

def isPaused() {
    if (!fileExists(path())) { return null }
    return readJSON(file: path())
}

def pause(String reason, Map extra = [:]) {
    def already = isPaused()
    if (already) { return false }
    def state = [reason: reason, since: new Date().toString(), run: env.BUILD_URL ?: '']
    state.putAll(extra)
    sh "mkdir -p '${env.JENKINS_HOME}/agent-pipeline'"
    writeJSON(file: path(), json: state, pretty: 2)
    return true
}

def clear() {
    if (!fileExists(path())) { return false }
    sh "rm -f '${path()}'"
    return true
}
