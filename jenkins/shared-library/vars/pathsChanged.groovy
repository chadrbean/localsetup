// pathsChanged(['terraform/', 'ci/jenkins/terraform.Jenkinsfile'])
// true when not push-triggered (cron/manual/upstream always run), when the change
// set is unknown, or when any changed file starts with one of the prefixes.
// 'indexing' builds are treated like pushes (they mean a webhook was missed).
def call(List prefixes) {
    if (!(triggeredBy() in ['scm', 'indexing'])) { return true }
    def files = changedFiles()
    if (files == null) { return true }
    return files.any { f -> prefixes.any { p -> f.startsWith(p) } }
}
