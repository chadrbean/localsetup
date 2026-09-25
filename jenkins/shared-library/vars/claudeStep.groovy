// def r = claudeStep(stage: 'plan', prompt: '/speckit-plan', image: 'localhost/ci-claude:1',
//                    model: 'opus', maxTurns: 250, minutes: 90)
// One headless Claude Code run (claude -p) in the repo checkout ./repo, inside the agent
// image. The container is the sandbox: workspace mount only, no podman socket, no cloud
// or GitHub credentials — just the 'agent-claude-oauth-token' (claude setup-token).
//   prompt   -> .agent/prompts/<stage>.md (piped on stdin, so issue text is never shell-quoted)
//   rules    -> resources/agent/headless-prompt.md via --append-system-prompt (never ask)
//   output   -> .agent/logs/<stage>.jsonl (stream-json transcript, archived by the worker)
// Returns [text: final message, turns: n, cost: usd]; error() when Claude reports an error.
// Commits Claude makes are authored by jenkins-agent (NOT jenkins-bot, so skipIfBotCommit
// doesn't skip the repo's own PR checks on agent PRs). See docs/AGENT-PIPELINE.md.
def call(Map a) {
    def stage = a.stage
    def model = a.model ? "--model '${a.model}'" : ''
    writeFile file: '.agent/headless-prompt.md', text: libraryResource('agent/headless-prompt.md')
    writeFile file: ".agent/prompts/${stage}.md", text: a.prompt
    def args = ['-u 0:0', '-e IS_SANDBOX=1', '-e HOME=/root',
                '-e GIT_AUTHOR_NAME=jenkins-agent', '-e GIT_COMMITTER_NAME=jenkins-agent',
                '-e GIT_AUTHOR_EMAIL=jenkins-agent@chadrbean.com',
                '-e GIT_COMMITTER_EMAIL=jenkins-agent@chadrbean.com'].join(' ')
    timeout(time: (a.minutes ?: 90) as int, unit: 'MINUTES') {
        withCredentials([string(credentialsId: 'agent-claude-oauth-token', variable: 'CLAUDE_CODE_OAUTH_TOKEN')]) {
            docker.image(a.image).inside(args) {
                dir('repo') {
                    sh """
                      mkdir -p ../.agent/logs
                      claude -p --verbose --output-format stream-json \\
                        --permission-mode bypassPermissions --max-turns ${a.maxTurns ?: 250} ${model} \\
                        --add-dir ../.agent \\
                        --append-system-prompt "\$(cat ../.agent/headless-prompt.md)" \\
                        < '../.agent/prompts/${stage}.md' > '../.agent/logs/${stage}.jsonl' || true
                    """
                }
            }
        }
    }
    def lines = readFile(".agent/logs/${stage}.jsonl").readLines().findAll { it.startsWith('{"type":"result"') }
    if (!lines) { error("claudeStep ${stage}: no result in transcript (crash or auth failure) — see .agent/logs/${stage}.jsonl") }
    def r = readJSON(text: lines[-1])
    def text = (r.result ?: '').toString()
    writeFile file: ".agent/logs/${stage}.md", text: text
    echo "claudeStep ${stage}: ${r.subtype}, ${r.num_turns} turns, \$${r.total_cost_usd}\n${text}"
    if (r.is_error || r.subtype != 'success') {
        error("claudeStep ${stage}: ${r.subtype}${r.is_error ? ' (is_error)' : ''} — ${text.length() > 300 ? text.substring(0, 300) : text}")
    }
    return [text: text, turns: r.num_turns, cost: r.total_cost_usd]
}
