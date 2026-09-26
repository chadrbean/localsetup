@Library('ci') _

// localsetup/ci (jenkins/casc/github/seed.groovy): security + lint checks for this repo on main
// and PRs. Every check comes from ci/checks.yml and runs through runCheck, so its catalog
// category decides the colour: blocking -> red, advisory -> yellow. Every check runs even when
// an earlier one fails. Rules: docs/ci-gates.md. Spec: specs/002-all-project-pipelines.
//   Checks » security   gitleaks (blocking), trivy-config (advisory; .trivyignore.yaml)
//   Checks » lint       shellcheck (blocking), check-syntax (blocking)

pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    environment {
        GITHUB_STEP_SUMMARY = "${WORKSPACE}/summary.md"
    }

    stages {
        stage('Prepare') {
            steps {
                script {
                    sh 'rm -f summary.md gitleaks.sarif trivy.sarif shellcheck.xml'
                    env.SKIP = skipIfBotCommit()
                }
            }
        }

        // Same shape as blogLosAngeles delivery: Checks = parallel groups. Each check runs in the
        // image that has its tool (gitleaks: ci-hugo; trivy + python/yaml: ci-terraform).
        stage('Checks') {
            when { expression { env.SKIP != 'true' } }
            parallel {
                stage('security') {
                    steps {
                        script {
                            docker.image('localhost/ci-hugo:1').inside('-u 0:0') { runCheck(id: 'gitleaks') }
                            docker.image('localhost/ci-terraform:1').inside('-u 0:0') { runCheck(id: 'trivy-config') }
                        }
                    }
                }
                stage('lint') {
                    steps {
                        script {
                            docker.image('docker.io/koalaman/shellcheck-alpine:v0.11.0').inside('-u 0:0') { runCheck(id: 'shellcheck') }
                            docker.image('localhost/ci-terraform:1').inside('-u 0:0') { runCheck(id: 'check-syntax') }
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            publishReports(gitleaks: 'gitleaks.sarif', trivy: 'trivy.sarif', shellcheck: 'shellcheck.xml')
            checkReport()
            stepSummary()
        }
        failure { notifyFailure() }
    }
}
