// withAwsRole('blog-deploy') { sh 'aws s3 ls' }
// withAwsRole('zca-dev', [duration: 7200, region: 'us-west-2']) { ... }
//
// Replaces aws-actions/configure-aws-credentials + GitHub OIDC. Exchanges the
// role's X.509 cert for short-lived STS creds via IAM Roles Anywhere
// (aws_signing_helper) and exposes them as AWS_* env vars for the body only.
//
// The helper runs in the Jenkins CONTROLLER JVM (ProcessBuilder), not via `sh`,
// so it also works inside docker.image().inside{} / agent { docker } blocks,
// where `sh` executes in the build container (which has neither the helper nor
// the certs). This is a trusted global library, so the sandbox does not apply.
import groovy.json.JsonSlurperClassic

def call(String key, Map opts = [:], Closure body) {
    def roles = new JsonSlurperClassic().parseText(libraryResource('aws-roles.json'))
    def role = roles[key]
    if (!role) { error "withAwsRole: unknown role key '${key}' (see jenkins/shared-library/resources/aws-roles.json)" }
    int duration = (opts.duration ?: 3600) as int
    def creds = fetch(role.roleArn as String, role.cn as String, duration)
    def region = opts.region ?: env.AWS_REGION ?: 'us-west-2'
    wrap([$class: 'MaskPasswordsBuildWrapper',
          varPasswordPairs: [[password: creds.SecretAccessKey], [password: creds.SessionToken]]]) {
        withEnv(["AWS_ACCESS_KEY_ID=${creds.AccessKeyId}",
                 "AWS_SECRET_ACCESS_KEY=${creds.SecretAccessKey}",
                 "AWS_SESSION_TOKEN=${creds.SessionToken}",
                 "AWS_REGION=${region}",
                 "AWS_DEFAULT_REGION=${region}"]) {
            body()
        }
    }
}

@NonCPS
private Map fetch(String roleArn, String cn, int duration) {
    def e = System.getenv()
    def dir = e.RA_CERT_DIR ?: '/run/jenkins-secrets/roles-anywhere'
    if (!e.RA_TRUST_ANCHOR_ARN || !e.RA_PROFILE_ARN) {
        throw new IllegalStateException('RA_TRUST_ANCHOR_ARN / RA_PROFILE_ARN not set on the controller (jenkins/.env)')
    }
    def cmd = ['aws_signing_helper', 'credential-process',
               '--certificate', "${dir}/${cn}.pem".toString(),
               '--private-key', "${dir}/${cn}.key".toString(),
               '--trust-anchor-arn', e.RA_TRUST_ANCHOR_ARN,
               '--profile-arn', e.RA_PROFILE_ARN,
               '--role-arn', roleArn,
               '--session-duration', duration.toString()]
    def p = new ProcessBuilder(cmd).start()
    def out = p.inputStream.text
    def err = p.errorStream.text
    if (p.waitFor() != 0) { throw new IllegalStateException("aws_signing_helper failed for ${cn}: ${err.trim()}") }
    return new JsonSlurperClassic().parseText(out) as Map
}
