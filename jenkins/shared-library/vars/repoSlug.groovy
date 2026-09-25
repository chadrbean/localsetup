// 'owner/repo' for the current multibranch build, derived from the job path
// (seed.groovy names folders after the GitHub repo; owner is fixed).
def call() {
    def repo = env.JOB_NAME.tokenize('/')[0]
    return "${env.GITHUB_OWNER ?: 'chadrbean'}/${repo}"
}
