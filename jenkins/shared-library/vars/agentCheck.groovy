// agentCheck('pytest', 'python3 -m pytest -q scripts')
// One validation command for a repo's ci/jenkins/agent-validate.groovy. Output goes to
// the console AND to $AGENT_DIR/validate/<name>.log; failing names are appended to
// $AGENT_DIR/validate/FAILED so the agent worker hands exactly those logs to Claude for
// a fix pass. Outside the worker (no AGENT_DIR) it's a plain sh. docs/AGENT-PIPELINE.md
def call(String name, String cmd) {
    if (!env.AGENT_DIR) { sh cmd; return }
    def dir = "${env.AGENT_DIR}/validate"
    def slug = name.replaceAll('[^A-Za-z0-9_.-]+', '-')
    writeFile file: "${dir}/${slug}.sh", text: cmd + '\n'
    sh """
      set +e
      sh -e '${dir}/${slug}.sh' > '${dir}/${slug}.log' 2>&1
      rc=\$?
      cat '${dir}/${slug}.log'
      if [ \$rc -ne 0 ]; then
        echo '${slug}' >> '${dir}/FAILED'
        echo "agentCheck: ${name} failed (exit \$rc)"
      fi
      exit \$rc
    """
}
