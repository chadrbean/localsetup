// post { always { notifyOverride() } } — emails when runCheck let a blocking failure through
// because of OVERRIDE_REASON (manual main builds only), so every override leaves a trail.
def call() {
    if (!env.OVERRIDDEN_CHECKS) { return }
    emailext(
        to: env.ALERT_EMAIL_TO ?: 'crb4u@yahoo.com',
        subject: "[Jenkins] OVERRIDE used: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
        body: "${env.JOB_NAME} #${env.BUILD_NUMBER} bypassed blocking check(s): ${env.OVERRIDDEN_CHECKS}\n" +
              "Reason: ${params.OVERRIDE_REASON}\nResult: ${currentBuild.currentResult}\n\n${env.BUILD_URL}\n",
        mimeType: 'text/plain')
}
