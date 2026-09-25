// publishReports(junit: 'reports/junit/*.xml', coverage: 'coverage/cobertura-coverage.xml',
//                eslint: 'reports/eslint.xml', checkov: 'checkov.sarif',
//                trivy: 'trivy.sarif', gitleaks: 'gitleaks.sarif',
//                html: [[dir: 'playwright-report', name: 'Playwright']])
// Call from post { always { ... } }. Turns tool output into build pages + job trends
// (junit, coverage, warnings-ng, htmlpublisher plugins). Every input is optional and
// skipped when its glob matches nothing, so one call fits every pipeline.
// Formats: junit XML, Cobertura XML, ESLint checkstyle/json, SARIF for the scanners.
// Options: label (prefix for ids/names, e.g. the terraform dir, when a build publishes
// the same tool twice), failOnNewIssues (mark UNSTABLE when a scanner reports issues
// not present in the reference build).
def call(Map a = [:]) {
    def has = { String glob -> glob && findFiles(glob: glob).size() > 0 }
    def pre = a.label ? "${a.label.replaceAll('[^A-Za-z0-9]+', '-')}-" : ''
    def title = { String name -> a.label ? "${a.label} ${name}" : name }

    def tools = []
    if (has(a.eslint)) { tools << esLint(pattern: a.eslint, id: "${pre}eslint", name: title('ESLint')) }
    ['checkov': 'Checkov', 'trivy': 'Trivy', 'gitleaks': 'Gitleaks'].each { key, name ->
        if (has(a[key])) { tools << sarif(pattern: a[key], id: "${pre}${key}", name: title(name)) }
    }
    def coverage = has(a.coverage)

    // Baseline for new/fixed issues and coverage deltas: the previous build here, or the
    // target branch's last build on PRs. Without it nothing is ever counted as NEW.
    if ((tools || coverage) && !env.REPORTS_REFERENCE_SET) {
        discoverReferenceBuild()
        env.REPORTS_REFERENCE_SET = 'true'
    }

    if (has(a.junit)) {
        junit testResults: a.junit, allowEmptyResults: true, skipPublishingChecks: true
    }
    if (coverage) {
        recordCoverage tools: [[parser: 'COBERTURA', pattern: a.coverage]],
                       id: "${pre}coverage", name: title('Coverage'), skipPublishingChecks: true
    }
    if (tools) {
        def gates = a.failOnNewIssues ? [[threshold: 1, type: 'NEW', criticality: 'UNSTABLE']] : []
        // one Issues page (and trend) per tool
        recordIssues tools: tools, qualityGates: gates, skipPublishingChecks: true,
                     enabledForFailure: true
    }

    (a.html ?: []).each { h ->
        def index = h.index ?: 'index.html'
        if (has("${h.dir}/${index}")) {
            publishHTML target: [reportDir: h.dir, reportFiles: index, reportName: h.name ?: h.dir,
                                 keepAll: true, alwaysLinkToLastBuild: true, allowMissing: true]
        }
    }
}
