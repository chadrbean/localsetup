// ci/jenkins/agent-validate.groovy — done-gate for the agent feature pipeline on THIS repo
// (docs/AGENT-PIPELINE.md). agent/feature-worker loads this from main (never from the agent's
// branch) and calls validate(cfg) at the repo root. A failing agentCheck hands its log back to
// Claude for a fix pass.
//
// Mirrors the blocking checks in ci/checks.yml (what ci/jenkins/ci.Jenkinsfile runs on PRs), in
// the same images. trivy-config is advisory there, so it isn't a gate here either. Changes under
// jenkins/, ci/jenkins/ and .github/ never auto-merge (config.json manualMergePaths).

def validate(cfg) {
    docker.image('localhost/ci-hugo:1').inside('-u 0:0') {
        // Only the agent's own commits: the full history is the PR job's business.
        agentCheck('gitleaks', 'gitleaks git --no-banner --redact --exit-code 1 --log-opts="origin/main..HEAD" .')
    }
    docker.image('docker.io/koalaman/shellcheck-alpine:v0.11.0').inside('-u 0:0') {
        // .specify/ is vendored spec-kit (upstream-managed), excluded exactly as in ci/checks.yml.
        agentCheck('shellcheck', "find . -name '*.sh' -not -path './.git/*' -not -path './.agent-validate/*' -not -path './.specify/*' | xargs shellcheck -S warning -f gcc")
    }
    docker.image('localhost/ci-terraform:1').inside('-u 0:0') {
        agentCheck('check-syntax', 'python3 ci/check_syntax.py')
    }
}

return this
