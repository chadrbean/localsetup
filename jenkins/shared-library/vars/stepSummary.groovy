// Replaces $GITHUB_STEP_SUMMARY. Pipelines set
//   environment { GITHUB_STEP_SUMMARY = "${WORKSPACE}/summary.md" }
// so existing repo scripts that append to it keep working; call stepSummary()
// in post { always } to archive it with the build. Its first heading/line is also
// shown on the build page (badge plugin), linking to the full file.
def call(String file = 'summary.md') {
    if (fileExists(file)) {
        archiveArtifacts artifacts: file, allowEmptyArchive: true
        def first = readFile(file).readLines().find { it.trim() }
        if (first) {
            addSummary icon: 'symbol-document-text-outline plugin-ionicons-api',
                       text: first.replaceFirst(/^#+\s*/, ''),
                       link: "${env.BUILD_URL}artifact/${file}"
        }
    }
}
