// Job DSL seed, run by JCasC on every Jenkins start (idempotent).
// One folder per GitHub repo, one multibranch job per pipeline file:
//   <repo>/<pipeline>  ->  ci/jenkins/<pipeline>.Jenkinsfile  (main + PRs only)
// Each job posts its own GitHub status context "jenkins/<pipeline>" so several
// pipelines on one repo don't overwrite each other's PR checks.
// To add a pipeline: add it below, commit, restart Jenkins (or reload JCasC).
def owner = 'chadrbean'
def pipelines = [
    'aws-infrastructure': ['terraform', 'drift'],
    'blogLosAngeles'    : ['deploy', 'security-gate', 'security-live', 'seo-live-crawl', 'smoketests', 'terraform'],
    'TraderIntel'       : ['ci-cd'],
    'zca-accounting'    : ['ci', 'deploy-dev', 'deploy-prod'],
]

pipelines.each { repo, names ->
    folder(repo) {
        description("Pipelines for github.com/${owner}/${repo} (ci/jenkins/*.Jenkinsfile)")
    }
    names.each { name ->
        multibranchPipelineJob("${repo}/${name}") {
            description("ci/jenkins/${name}.Jenkinsfile on main + PRs")
            branchSources {
                branchSource {
                    source {
                        github {
                            id("${repo}-${name}")
                            repoOwner(owner)
                            repository(repo)
                            repositoryUrl("https://github.com/${owner}/${repo}")
                            configuredByUrl(false)
                            credentialsId('github-app')
                            traits {
                                // 1 = exclude branches that are also filed as PRs
                                gitHubBranchDiscovery { strategyId(1) }
                                // 1 = build the PR merged with its target (HEAD^1 = target)
                                gitHubPullRequestDiscovery { strategyId(1) }
                                headWildcardFilter {
                                    includes('main PR-*')
                                    excludes('')
                                }
                                notificationContextTrait {
                                    contextLabel("jenkins/${name}")
                                    typeSuffix(false)
                                }
                            }
                        }
                    }
                    // Don't fire every pipeline (incl. deploys) when a job is first
                    // created/indexed; later webhook events build normally.
                    buildStrategies {
                        skipInitialBuildOnFirstBranchIndexing()
                    }
                }
            }
            factory {
                workflowBranchProjectFactory {
                    scriptPath("ci/jenkins/${name}.Jenkinsfile")
                }
            }
            orphanedItemStrategy {
                discardOldItems {
                    daysToKeep(14)
                }
            }
            triggers {
                // Safety net for missed webhooks.
                periodicFolderTrigger { interval('1d') }
            }
        }
    }
}

folder('ci-maintenance') {
    description('Jobs that keep the CI platform itself healthy')
}

// Weekly: fail + email when any Roles Anywhere leaf cert (Jenkins or host) has
// < 30 days left. scripts/jenkins_ca.sh copies every issued public cert to
// ~/.local/share/jenkins/ca/issued/, mounted read-only at /run/jenkins-ca-issued.
pipelineJob('ci-maintenance/cert-expiry') {
    description('Roles Anywhere certificate expiry check (renew with scripts/jenkins_ca.sh)')
    properties { pipelineTriggers { triggers { cron { spec('H 9 * * 1') } } } }
    definition {
        cps {
            sandbox(true)
            script('''
pipeline {
  agent any
  options { timestamps() }
  stages {
    stage('Check') {
      steps {
        sh \'\'\'
          fail=0; n=0
          for c in /run/jenkins-ca-issued/*.pem; do
            [ -e "$c" ] || continue; n=$((n+1))
            end=$(openssl x509 -enddate -noout -in "$c" | cut -d= -f2)
            if openssl x509 -checkend $((30*86400)) -noout -in "$c" >/dev/null; then
              echo "ok       $(basename "$c")  expires $end"
            else
              echo "EXPIRING $(basename "$c")  expires $end"; fail=1
            fi
          done
          [ "$n" -gt 0 ] || { echo "no issued certs found"; exit 1; }
          exit $fail
        \'\'\'
      }
    }
  }
  post {
    failure {
      emailext(to: env.ALERT_EMAIL_TO, subject: "[Jenkins] Roles Anywhere cert expiring",
               body: "${env.BUILD_URL}console — renew with scripts/jenkins_ca.sh issue <cn>", mimeType: 'text/plain')
    }
  }
}
'''.stripIndent())
        }
    }
}

// Manual: prove a role key works end to end (cert -> Roles Anywhere -> STS).
pipelineJob('ci-maintenance/aws-role-smoke') {
    description('withAwsRole(<key>) + aws sts get-caller-identity')
    parameters {
        choiceParam('ROLE_KEY', ['aws-infrastructure', 'blog-deploy', 'blog-terraform', 'zca-dev', 'zca-prod', 'traderintel'], 'Key from jenkins/shared-library/resources/aws-roles.json')
    }
    definition {
        cps {
            sandbox(true)
            script('''
@Library('ci') _
pipeline {
  agent any
  stages {
    stage('Assume') {
      steps { script { withAwsRole(params.ROLE_KEY) { sh 'aws sts get-caller-identity' } } }
    }
  }
}
'''.stripIndent())
        }
    }
}
