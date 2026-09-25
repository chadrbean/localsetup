// post { failure { notifyFailure() } } — email on main-branch / scheduled failures
// via SES SMTP (JCasC email-ext config). PR failures show on the GitHub check instead.
def call() {
    if (env.CHANGE_ID) { return }
    emailext(
        to: env.ALERT_EMAIL_TO ?: 'crb4u@yahoo.com',
        subject: "[Jenkins] FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
        body: "${env.JOB_NAME} #${env.BUILD_NUMBER} failed (trigger: ${triggeredBy()}).\n\n${env.BUILD_URL}console\n",
        mimeType: 'text/plain')
}
