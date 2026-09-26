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
//
// The STS role session name is the Jenkins BUILD_TAG (override: opts.sessionName), so
// CloudTrail shows assumed-role/<role>/jenkins-<job>-<build> instead of the cert serial and
// every AWS API call ties back to the build that made it.
import groovy.json.JsonSlurperClassic

def call(String key, Map opts = [:], Closure body) {
    def roles = new JsonSlurperClassic().parseText(libraryResource('aws-roles.json'))
    def role = roles[key]
    if (!role) { error "withAwsRole: unknown role key '${key}' (see jenkins/shared-library/resources/aws-roles.json)" }
    int duration = (opts.duration ?: 3600) as int
    String session = toSessionName((opts.sessionName ?: env.BUILD_TAG ?: '') as String)
    def creds = fetch(role.roleArn as String, role.cn as String, duration, session)
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

// STS role session names allow [\w+=,.@-], 2-64 chars. Keep the TAIL when truncating: the build
// number is the part that tells builds apart. '' means no name (the helper then defaults to
// the cert serial), e.g. when called outside a build.
@NonCPS
private String toSessionName(String raw) {
    String s = raw.replaceAll(/[^\w+=,.@-]/, '-')
    if (s.length() > 64) { s = s.substring(s.length() - 64) }
    return s.length() >= 2 ? s : ''
}

@NonCPS
private Map fetch(String roleArn, String cn, int duration, String session) {
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
    if (session) { cmd += ['--role-session-name', session] }
    def p = new ProcessBuilder(cmd).start()
    def out = p.inputStream.text
    def err = p.errorStream.text
    if (p.waitFor() != 0) { throw new IllegalStateException("aws_signing_helper failed for ${cn}: ${err.trim()}") }
    return new JsonSlurperClassic().parseText(out) as Map
}
