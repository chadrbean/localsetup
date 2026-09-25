@Library('ci') _

// localsetup/ci (jenkins/casc/github/seed.groovy): lint + security checks for this repo
// on main and PRs. Every check runs even if an earlier one fails (catchError), and
// all of them land on the build page via publishReports.
//   Secrets  gitleaks over full history — any leak not in .gitleaksignore fails
//   Config   trivy config (Containerfiles, compose) — report; UNSTABLE on new findings
//   Shell    shellcheck — warnings/errors fail
//   Syntax   ci/check_syntax.py (Python, YAML, JSON incl. dashboards) — errors fail

pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    stages {
        stage('Gate') {
            steps { script { env.SKIP = skipIfBotCommit() } }
        }

        stage('Secrets') {
            when { expression { env.SKIP != 'true' } }
            agent { docker { image 'localhost/ci-hugo:1'; args '-u 0:0'; reuseNode true } }
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    sh 'gitleaks git --no-banner --redact --report-format sarif --report-path gitleaks.sarif .'
                }
            }
        }

        stage('Config') {
            when { expression { env.SKIP != 'true' } }
            agent { docker { image 'localhost/ci-terraform:1'; args '-u 0:0'; reuseNode true } }
            steps {
                sh 'trivy config --quiet --format sarif --output trivy.sarif .'
                sh 'trivy config --quiet .'
            }
        }

        stage('Shell') {
            when { expression { env.SKIP != 'true' } }
            agent { docker { image 'docker.io/koalaman/shellcheck-alpine:v0.11.0'; args '-u 0:0'; reuseNode true } }
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    sh '''
                        find . -name '*.sh' -not -path './.git/*' > sh-files.txt
                        xargs shellcheck -f checkstyle < sh-files.txt > shellcheck.xml || true
                        xargs shellcheck -S warning -f gcc < sh-files.txt
                    '''
                }
            }
        }

        stage('Syntax') {
            when { expression { env.SKIP != 'true' } }
            agent { docker { image 'localhost/ci-terraform:1'; args '-u 0:0'; reuseNode true } }
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    sh 'python3 ci/check_syntax.py'
                }
            }
        }
    }

    post {
        always {
            publishReports(gitleaks: 'gitleaks.sarif', trivy: 'trivy.sarif',
                           shellcheck: 'shellcheck.xml', failOnNewIssues: true)
        }
        failure { notifyFailure() }
    }
}
