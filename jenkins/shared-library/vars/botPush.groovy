// botPush(message: 'chore: archive past events', paths: 'site/content')
// Commits as jenkins-bot and pushes to main with rebase-before-push (same as the
// old Actions jobs). The '[skip ci]' marker + skipIfBotCommit() in every pipeline
// stop the push from re-triggering builds (Actions got this for free: pushes
// made with GITHUB_TOKEN never trigger workflows).
def call(Map a) {
    def paths = a.paths ?: '.'
    def slug = repoSlug()
    withGitHubToken {
        sh """
          git config user.name 'jenkins-bot'
          git config user.email '${botEmail()}'
          git add -A ${paths}
          if git diff --cached --quiet; then echo 'botPush: nothing to commit'; exit 0; fi
          git commit -m '${a.message} [skip ci]'
          auth="AUTHORIZATION: basic \$(printf 'x-access-token:%s' "\$GH_TOKEN" | base64 -w0)"
          url='https://github.com/${slug}.git'
          git -c http.extraHeader="\$auth" pull --rebase "\$url" main
          git -c http.extraHeader="\$auth" push "\$url" HEAD:main
        """
    }
}
