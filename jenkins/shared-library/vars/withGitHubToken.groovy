// withGitHubToken { sh 'gh pr comment ...' }
// Binds a short-lived GitHub App installation token as GH_TOKEN / GITHUB_TOKEN
// (replaces the Actions GITHUB_TOKEN). Needs the 'github-app' credential (JCasC).
def call(Closure body) {
    withCredentials([usernamePassword(credentialsId: 'github-app',
                                      usernameVariable: 'GH_APP_ID',
                                      passwordVariable: 'GH_TOKEN')]) {
        withEnv(['GITHUB_TOKEN=' + env.GH_TOKEN]) { body() }
    }
}
