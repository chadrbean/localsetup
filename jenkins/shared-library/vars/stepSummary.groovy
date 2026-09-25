// Replaces $GITHUB_STEP_SUMMARY. Pipelines set
//   environment { GITHUB_STEP_SUMMARY = "${WORKSPACE}/summary.md" }
// so existing repo scripts that append to it keep working; call stepSummary()
// in post { always } to archive it with the build.
def call(String file = 'summary.md') {
    if (fileExists(file)) {
        archiveArtifacts artifacts: file, allowEmptyArchive: true
    }
}
