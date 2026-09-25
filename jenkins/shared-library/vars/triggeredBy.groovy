// 'cron' | 'manual' | 'upstream' | 'indexing' | 'scm' — replaces github.event_name.
//   scm      = GitHub webhook push/PR event (the normal case)
//   indexing = branch indexing found new commits (missed webhook, or a job's first
//              scan — seed.groovy skips the build on first indexing)
def call() {
    if (currentBuild.getBuildCauses('hudson.triggers.TimerTrigger$TimerTriggerCause')) { return 'cron' }
    if (currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause')) { return 'manual' }
    if (currentBuild.getBuildCauses('hudson.model.Cause$UpstreamCause')) { return 'upstream' }
    if (currentBuild.getBuildCauses('jenkins.branch.BranchIndexingCause')) { return 'indexing' }
    return 'scm'
}
