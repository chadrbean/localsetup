// prComment(file: 'comment.md') — no-op outside PR builds.
// Replaces actions/github-script issues.createComment. Truncates at 60k chars
// (GitHub's comment limit is 65,536).
def call(Map a) {
    if (!env.CHANGE_ID) { echo 'prComment: not a PR build, skipping'; return }
    def slug = repoSlug()
    withGitHubToken {
        sh """
          f='${a.file}'
          if [ \$(wc -c < "\$f") -gt 60000 ]; then
            head -c 60000 "\$f" > "\$f.trunc"
            printf '\\n\\n...(truncated, full output: %sconsole)\\n' "\$BUILD_URL" >> "\$f.trunc"
            f="\$f.trunc"
          fi
          gh pr comment "\$CHANGE_ID" --repo '${slug}' --body-file "\$f"
        """
    }
}
