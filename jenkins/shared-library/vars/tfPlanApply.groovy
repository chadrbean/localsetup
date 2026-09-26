// tfPlanApply(dir: 'terraform', role: 'aws-infrastructure', region: 'us-east-1')
// Replaces the terraform.yml workflows: fmt -> init -> validate -> [checkov, trivy]
// -> plan (-> PR comment) -> apply on main. Run it inside the ci-terraform image.
// The plan ALWAYS runs and is ALWAYS posted to the PR, even when fmt/validate/scanners report
// findings (a reviewer needs the plan most exactly then); the build fails afterwards.
// Pipelines with a ci/checks.yml run fmt/validate/scanners as catalogued runCheck stages before
// this step (spec 002) and call it WITHOUT preChecks; their per-check table (env.CHECK_RESULTS)
// is included in the PR comment, and apply is skipped when a blocking check already failed.
// Apply happens only for a push to main (webhook or indexing-detected), same as
// the old IS_APPLY rule; manual/cron/upstream builds on main only plan.
// Options: region (AWS_REGION for the provider), applyOnMain (default true; pass
// false or your own boolean to override), preChecks (legacy: checkov + trivy in here).
// plan/apply wait up to 10m for the S3 state lock: one push starts every multibranch
// job in the repo (e.g. aws-infrastructure terraform + drift) and they share a state.
def call(Map a) {
    def tfDir = a.dir ?: 'terraform'
    def pushed = triggeredBy() in ['scm', 'indexing']
    def isApply = !env.CHANGE_ID && env.BRANCH_NAME == 'main' && pushed && a.applyOnMain != false
    withAwsRole(a.role, [region: a.region]) {
        dir(tfDir) {
            def fmt = sh(script: 'terraform fmt -check -recursive', returnStatus: true)
            sh 'terraform init -input=false -no-color'
            def validate = sh(script: 'terraform validate -no-color', returnStatus: true)
            def scan = 0
            if (a.preChecks) {
                // SARIF copies feed the build's Issues pages. returnStatus: findings must not
                // stop the plan (and its PR comment) from running.
                scan += sh(returnStatus: true, script: 'checkov -d . --framework terraform --compact --quiet -o cli -o sarif --output-file-path console,checkov.sarif')
                scan += sh(returnStatus: true, script: 'trivy config --format sarif --output trivy.sarif . && trivy config --exit-code 1 .')
                publishReports(label: tfDir, checkov: 'checkov.sarif', trivy: 'trivy.sarif')
            }
            def plan = sh(script: 'set -o pipefail; terraform plan -input=false -lock-timeout=10m -no-color -out=tfplan 2>&1 | tee plan_output.txt',
                          returnStatus: true)
            if (env.CHANGE_ID) {
                def icon = { int rc -> rc == 0 ? '✅' : '❌' }
                def scanRow = a.preChecks ? "| checkov + trivy | ${icon(scan)} |\n" : ''
                def checks = env.CHECK_RESULTS ?
                    "\n**Checks** (the category decides pass/fail: docs/ci-gates.md)\n\n| check | stage | category | verdict | result |\n|---|---|---|---|---|\n${env.CHECK_RESULTS}\n" : ''
                writeFile file: 'comment.md', text: """### Terraform `${tfDir}` — Jenkins #${env.BUILD_NUMBER}
| Step | Result |
|---|---|
| fmt | ${icon(fmt)} |
| validate | ${icon(validate)} |
${scanRow}| plan | ${icon(plan)} |
${checks}
<details><summary>Plan output</summary>

```
${readFile('plan_output.txt')}
```
</details>

[Build log](${env.BUILD_URL}console)
"""
                prComment(file: 'comment.md')
            }
            if (fmt != 0 || validate != 0 || plan != 0 || scan != 0) {
                error "terraform fmt=${fmt} validate=${validate} scanners=${scan} plan=${plan}"
            }
            if (isApply && currentBuild.currentResult == 'FAILURE') {
                echo "Apply skipped: a blocking check failed earlier in this build (${env.BLOCKED_BY ?: 'see above'})"
            } else if (isApply) {
                sh 'terraform apply -input=false -lock-timeout=10m -no-color -auto-approve tfplan'
            }
        }
    }
}
