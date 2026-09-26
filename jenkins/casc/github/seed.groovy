// Job DSL seed, run by JCasC on every Jenkins start (idempotent).
// One folder per GitHub repo, one multibranch job per pipeline file:
//   <repo>/<pipeline>  ->  ci/jenkins/<pipeline>.Jenkinsfile  (main + PRs only)
// Each job posts its own GitHub status context "jenkins/<pipeline>" so several
// pipelines on one repo don't overwrite each other's PR checks.
// To add a pipeline: add it below, commit, restart Jenkins (or reload JCasC).
// Flags after the name (any order; contract: specs/002-all-project-pipelines/contracts/seed-job-flags.md):
//   :main    discover ONLY main (no PR-* branches): jobs that must never run a PR's code —
//            deploys, the local stack refresh, drift and site-health checks.
//   :manual  never build automatically on a push, PR event or branch indexing, so those events
//            leave no NOT_BUILT entries. Manual "Build", `build job:` (upstream) and cron
//            triggers declared in the Jenkinsfile still run.
def owner = 'chadrbean'
def pipelines = [
    // terraform = per-change (checks → plan → apply on main); drift = monthly monitoring (spec 002).
    'aws-infrastructure': ['terraform', 'drift:main:manual'],
    // delivery = the one per-change pipeline (build → checks → infrastructure → deploy → verify);
    // the other three are site-health (monitoring) jobs, started by delivery / cron / a person.
    // Spec: specs/001-blog-pipeline-visibility.
    // Retired and removed from Jenkins 2026-09-26: deploy, smoketests, security-gate, terraform.
    // Job DSL never deletes a job dropped from this list: see docs/CICD.md "Retiring a job".
    'blogLosAngeles'    : ['delivery', 'security-live:main:manual', 'seo-live-crawl:main:manual',
                           'data-health:main:manual'],
    // Constitution Principle XX (NON-NEGOTIABLE): every zca-accounting pipeline is manual-only.
    'zca-accounting'    : ['ci:manual', 'deploy-dev:main:manual', 'deploy-prod:main:manual',
                           'local-refresh:main:manual'],
    'localsetup'        : ['ci'],
]

pipelines.each { repo, entries ->
    folder(repo) {
        description("Pipelines for github.com/${owner}/${repo} (ci/jenkins/*.Jenkinsfile)")
    }
    entries.each { entry ->
        def parts = entry.tokenize(':')
        def name = parts[0]
        def mainOnly = parts.contains('main')
        def manual = parts.contains('manual')
        multibranchPipelineJob("${repo}/${name}") {
            description("ci/jenkins/${name}.Jenkinsfile on " + (mainOnly ? 'main only' : 'main + PRs') +
                        (manual ? ', manual / upstream / cron only' : ''))
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
                                    includes(mainOnly ? 'main' : 'main PR-*')
                                    excludes('')
                                }
                                notificationContextTrait {
                                    contextLabel("jenkins/${name}")
                                    typeSuffix(false)
                                }
                            }
                        }
                    }
                    // Build only when BOTH hold (buildAllBranches = AND; a bare list is OR):
                    //  - the head is a PR (built from its FIRST commit), OR it's a branch
                    //    that isn't being seen for the first time. skipInitialBuildOnFirstBranchIndexing
                    //    is `lastSeenRevision != null && != currRevision` (plugin 317): it
                    //    skips the first revision of EVERY new head, even via a webhook.
                    //    On its own it meant no PR's opening commit ever built, so PRs got no
                    //    jenkins/<pipeline> status (found 2026-09-26: every localsetup PR
                    //    since #21). It still guards branches, so (re)creating a job never
                    //    fires a main deploy/apply;
                    //  - a human committed: jenkins-bot's [skip ci] botPush commits (blog
                    //    archive/purge) create no build at all, instead of a NOT_BUILT run
                    //    that clutters history (spec 001 FR-012). skipIfBotCommit() in the
                    //    pipelines stays as a backstop.
                    buildStrategies {
                        if (manual) {
                            // :manual — ALL of (is a regular branch, is a pull request) matches
                            // no head, so no push, PR event or indexing ever starts a build.
                            // Branch build strategies don't apply to manual, upstream (`build
                            // job:`) or cron builds, so those still run. (Only @Symbol'd
                            // strategies are used: a bad Job DSL name fails the seed at boot.)
                            buildAllBranches {
                                strategies {
                                    buildRegularBranches()
                                    buildChangeRequests {
                                        ignoreTargetOnlyChanges(false)
                                        ignoreUntrustedChanges(false)
                                    }
                                }
                            }
                        } else {
                            buildAllBranches {
                                strategies {
                                    buildAnyBranches {
                                        strategies {
                                            buildChangeRequests {
                                                ignoreTargetOnlyChanges(false)
                                                ignoreUntrustedChanges(false)
                                            }
                                            skipInitialBuildOnFirstBranchIndexing()
                                        }
                                    }
                                    ignoreCommitterStrategy {
                                        ignoredAuthors('jenkins-bot@chadrbean.com')
                                        // true = still build when any commit in the push is human
                                        allowBuildIfNotExcludedAuthor(true)
                                    }
                                }
                            }
                        }
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

// Agent feature pipeline (docs/AGENT-PIPELINE.md): GitHub Projects card Ready -> spec-kit +
// headless Claude Code -> PR -> Review. Pipelines live in THIS repo (ci/jenkins/feature-*),
// not in the target repos, so e.g. zca's manual-only CI rule is untouched. Which repos may be
// worked on: jenkins/shared-library/resources/agent/config.json (allowlist).
folder('agent') {
    description('Agent feature pipeline: Ready cards on the GitHub Project -> spec-kit + Claude Code -> PR (docs/AGENT-PIPELINE.md)')
}

def agentJob = { String name, String desc, Closure extra ->
    pipelineJob("agent/${name}") {
        description(desc)
        definition {
            cpsScm {
                scm {
                    git {
                        remote {
                            url("https://github.com/${owner}/localsetup")
                            credentials('github-app')
                        }
                        branch('main')
                    }
                }
                scriptPath("ci/jenkins/${name}.Jenkinsfile")
                lightweight(true)
            }
        }
        extra.resolveStrategy = Closure.DELEGATE_FIRST
        extra.delegate = delegate
        extra()
    }
}

agentJob('feature-dispatcher', 'Every 5 min: claim Ready cards (WIP per repo) and start feature-worker for each') {
    properties { pipelineTriggers { triggers { cron { spec('H/5 * * * *') } } } }
}

// Parameters are declared here too (not only in the Jenkinsfile) so the dispatcher's
// `build job:` parameters are accepted on the job's very first run.
agentJob('feature-worker', 'One issue: specify -> plan -> checklist -> tasks -> analyze -> implement -> validate -> PR') {
    parameters {
        stringParam('REPO', '', 'owner/repo (must be allowlisted in resources/agent/config.json)')
        stringParam('ISSUE', '', 'Issue number in REPO')
        stringParam('ITEM_ID', '', 'Project item id (set by the dispatcher; blank = manual run, no board updates)')
    }
}

// blogLosAngeles landing view: per-change delivery first, then the site-health jobs. Stage-level
// detail is on the delivery job page (pipeline-graph-view) and the Grafana "CI — blog delivery"
// dashboard (monitoring/dashboards/ci-blog-delivery.json).
listView('blogLosAngeles/Overview') {
    description('delivery = every PR and main change; security-live / seo-live-crawl / data-health = site health (alerts, never blocks). Rules: blogLosAngeles docs/ci-gates.md')
    jobs {
        names('delivery', 'security-live', 'seo-live-crawl', 'data-health')
    }
    columns {
        status()
        weather()
        name()
        lastSuccess()
        lastFailure()
        lastDuration()
        buildButton()
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
        choiceParam('ROLE_KEY', ['aws-infrastructure', 'blog-deploy', 'blog-terraform', 'zca-dev'],
                    'Key from jenkins/shared-library/resources/aws-roles.json (zca-prod omitted: its IAM role does not exist yet)')
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
