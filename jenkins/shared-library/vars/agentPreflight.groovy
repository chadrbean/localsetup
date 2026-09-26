// def r = agentPreflight()  ->  [ok: true|false, reason: '…']
// Health check the agent feature pipeline runs before it hands out work: one tiny headless
// `claude -p` in the agent image with the pipeline's own token. Healthy only when the result
// event has is_error=false and the reply is exactly "ok" (the same strict test as
// scripts/agent_secrets.sh). Never fails the build itself. docs/AGENT-PIPELINE.md § Pause.
def call(String image = null) {
    def img = image ?: agentConfig().defaults.image
    def out = ''
    try {
        withCredentials([string(credentialsId: 'agent-claude-oauth-token', variable: 'CLAUDE_CODE_OAUTH_TOKEN')]) {
            docker.image(img).inside('-u 0:0 -e IS_SANDBOX=1 -e HOME=/root') {
                out = sh(returnStdout: true, script: '''
                    timeout 120 claude -p --output-format json --max-turns 1 "Reply with exactly: ok" 2>/dev/null || true
                ''').trim()
            }
        }
    } catch (hudson.AbortException e) {
        return [ok: false, reason: "health check could not run: ${e.message}"]
    }
    if (!out) { return [ok: false, reason: 'claude -p produced no output (crash, image or network problem)'] }
    def r
    try {
        r = readJSON(text: out.readLines().findAll { it.trim().startsWith('{') }[-1])
    } catch (Exception e) {
        return [ok: false, reason: 'claude -p output was not JSON']
    }
    def text = (r.result ?: '').toString().trim()
    if (r.is_error) { return [ok: false, reason: text.length() > 200 ? text.substring(0, 200) : text] }
    if (text.toLowerCase().replaceAll('\\.$', '') != 'ok') { return [ok: false, reason: "unexpected reply: ${text.length() > 80 ? text.substring(0, 80) : text}"] }
    return [ok: true, reason: 'claude -p ok']
}
