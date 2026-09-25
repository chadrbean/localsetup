// List of paths changed by this build, or null when unknown (first build of a
// branch) — callers treat null as "changed". Replaces `on.*.paths` filters.
//   PR builds (merge strategy): HEAD^1 = target branch, so diff HEAD^1..HEAD.
//   Branch builds: Jenkins changeSets since the previous build.
def call() {
    if (env.CHANGE_ID) {
        return sh(script: 'git diff --name-only HEAD^1 HEAD', returnStdout: true).trim().split('\n').findAll { it } as List
    }
    def files = []
    currentBuild.changeSets.each { cs -> cs.items.each { e -> e.affectedPaths.each { files << it } } }
    return files ?: null
}
