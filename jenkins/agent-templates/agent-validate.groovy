// ci/jenkins/agent-validate.groovy — the agent feature pipeline's validation gate for THIS repo
// (localsetup docs/AGENT-PIPELINE.md). agent/feature-worker loads it from main (never from
// the agent's branch) and calls validate(cfg) with the cwd at the repo root, after Claude
// implements a feature. Throw (any failing sh / agentCheck) = not done: the worker gives
// Claude the failing checks' logs and retries, up to cfg.fixAttempts times.
//
// Rules:
//  - Wrap every command in agentCheck('<name>', '<cmd>') so its log reaches Claude.
//  - Run in the same images as this repo's own CI (agent { docker } equivalents below).
//  - Mirror the repo's PR gate, minus anything that needs cloud credentials or deploys.
//  - Keep it under ~20 min; the repo's real PR checks still run on the agent's PR.

def validate(cfg) {
    docker.image('localhost/ci-claude:1').inside('-u 0:0') {
        agentCheck('build', 'make build')
        agentCheck('test', 'make test')
        agentCheck('lint', 'make lint')
    }
    // Services (DB, cache) for integration tests, as in zca-accounting's agent-validate:
    // docker.image('postgres:15-alpine').withRun('-e POSTGRES_PASSWORD=localdev') { pg ->
    //     docker.image('golang:1.26.2-bookworm').inside("-u 0:0 --network container:${pg.id}") {
    //         agentCheck('go-test', 'go test ./...')
    //     }
    // }
}

return this
