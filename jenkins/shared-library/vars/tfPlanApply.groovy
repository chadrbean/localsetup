// tfPlanApply(dir: 'terraform', role: 'aws-infrastructure', preChecks: true)
// Replaces the terraform.yml workflows: fmt -> init -> validate -> [checkov, trivy]
// -> plan (-> PR comment) -> apply on main. Run it inside the ci-terraform image.
// On PRs a failing plan still posts its output, then fails the build.
// Apply happens only for a push to main (webhook or indexing-detected), same as
// the old IS_APPLY rule; manual/cron/upstream builds on main only plan.
// Options: region (AWS_REGION for the provider), applyOnMain (default true; pass
// false or your own boolean to override).
def call(Map a) {
    def tfDir = a.dir ?: 'terraform'
    def pushed = triggeredBy() in ['scm', 'indexing']
    def isApply = !env.CHANGE_ID && env.BRANCH_NAME == 'main' && pushed && a.applyOnMain != false
    withAwsRole(a.role, [region: a.region]) {
        dir(tfDir) {
            def fmt = sh(script: 'terraform fmt -check -recursive', returnStatus: true)
            sh 'terraform init -input=false -no-color'
            def validate = sh(script: 'terraform validate -no-color', returnStatus: true)
            if (a.preChecks) {
                // Same gates as before; SARIF copies feed the build's Issues pages.
                try {
                    sh 'checkov -d . --framework terraform --compact --quiet -o cli -o sarif --output-file-path console,checkov.sarif'
                    sh 'trivy config --format sarif --output trivy.sarif . && trivy config --exit-code 1 .'
                } finally {
                    publishReports(label: tfDir, checkov: 'checkov.sarif', trivy: 'trivy.sarif')
                }
            }
            def plan = sh(script: 'set -o pipefail; terraform plan -input=false -no-color -out=tfplan 2>&1 | tee plan_output.txt',
                          returnStatus: true)
            if (env.CHANGE_ID) {
                def icon = { int rc -> rc == 0 ? '✅' : '❌' }
                writeFile file: 'comment.md', text: """### Terraform `${tfDir}` — Jenkins #${env.BUILD_NUMBER}
| Step | Result |
|---|---|
| fmt | ${icon(fmt)} |
| validate | ${icon(validate)} |
| plan | ${icon(plan)} |

<details><summary>Plan output</summary>

```
${readFile('plan_output.txt')}
```
</details>

[Build log](${env.BUILD_URL}console)
"""
                prComment(file: 'comment.md')
            }
            if (fmt != 0 || validate != 0 || plan != 0) { error "terraform fmt=${fmt} validate=${validate} plan=${plan}" }
            if (isApply) {
                sh 'terraform apply -input=false -no-color -auto-approve tfplan'
            }
        }
    }
}
