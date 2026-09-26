// agentConfig()             -> the whole resources/agent/config.json (Map)
// agentConfig('owner/repo') -> that repo's settings merged over config.defaults, plus
//                              .repo (canonical name); error() if the repo isn't allowlisted.
// Agent feature pipeline, see docs/AGENT-PIPELINE.md.
def call(String repo = null) {
    def cfg = readJSON(text: libraryResource('agent/config.json'))
    if (repo == null) { return cfg }
    def name = cfg.repos.keySet().find { it.equalsIgnoreCase(repo) }
    if (!name) {
        error("agentConfig: ${repo} is not in the agent allowlist (jenkins/shared-library/resources/agent/config.json)")
    }
    def merged = [:]
    merged.putAll(cfg.defaults)
    merged.putAll(cfg.repos[name])
    merged.repo = name
    return merged
}
