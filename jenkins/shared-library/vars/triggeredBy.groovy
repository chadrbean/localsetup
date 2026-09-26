// 'cron' | 'manual' | 'upstream' | 'indexing' | 'scm' — replaces github.event_name.
//   scm      = GitHub webhook push/PR event (the normal case)
//   indexing = branch indexing found new commits (missed webhook, or a job's first
//              scan — seed.groovy skips a branch's first sighting; PRs always build)
def call() {
    if (currentBuild.getBuildCauses('hudson.triggers.TimerTrigger$TimerTriggerCause')) { return 'cron' }
    if (currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause')) { return 'manual' }
    // getBuildCauses() matches the exact class, not subclasses: a `build job:` step records
    // BuildUpstreamCause (a subclass of UpstreamCause), so check both.
    if (currentBuild.getBuildCauses('hudson.model.Cause$UpstreamCause') ||
        currentBuild.getBuildCauses('org.jenkinsci.plugins.workflow.support.steps.build.BuildUpstreamCause')) {
        return 'upstream'
    }
    if (currentBuild.getBuildCauses('jenkins.branch.BranchIndexingCause')) { return 'indexing' }
    return 'scm'
}
