#!/usr/bin/env bash
# Onboard a repo to the agent feature pipeline (docs/AGENT-PIPELINE.md § Onboarding).
#   scripts/agent_onboard.sh <owner/repo> <path-to-local-checkout> [image]
# Idempotent. Checks the repo contract, scaffolds what's missing (never overwrites), adds
# the repo to the dispatcher allowlist in this checkout, and links it to the Project.
# It does NOT commit or push anything: review, then commit in both repos yourself.
set -euo pipefail

repo=${1:?usage: agent_onboard.sh <owner/repo> <local-path> [image]}
path=${2:?usage: agent_onboard.sh <owner/repo> <local-path> [image]}
image=${3:-localhost/ci-claude:1}
here=$(cd "$(dirname "$0")/.." && pwd)
config="$here/jenkins/shared-library/resources/agent/config.json"
tpl="$here/jenkins/agent-templates"
todo=()

[ -d "$path/.git" ] || { echo "not a git checkout: $path" >&2; exit 1; }

# 1. spec-kit with the Claude integration (skills under .claude/skills/speckit-*)
if [ -d "$path/.specify" ] && ls -d "$path"/.claude/skills/speckit-specify >/dev/null 2>&1; then
  echo "ok    spec-kit (Claude skills) present"
else
  todo+=("install spec-kit: cd $path && uvx --from git+https://github.com/github/spec-kit.git specify init --here --ai claude --ai-skills, then add the git + companion extensions (see blogLosAngeles/.specify/extensions.yml)")
fi

# 2. constitution filled in (the thing Claude decides by instead of asking you)
const="$path/.specify/memory/constitution.md"
if [ -f "$const" ] && ! grep -q '\[PROJECT_NAME\]\|\[PRINCIPLE_1_NAME\]' "$const"; then
  echo "ok    constitution filled in"
else
  todo+=("write the constitution once, interactively: claude then /speckit-constitution (the one time you answer questions)")
fi

# 3. validation gate
mkdir -p "$path/ci/jenkins"
if [ -f "$path/ci/jenkins/agent-validate.groovy" ]; then
  echo "ok    ci/jenkins/agent-validate.groovy present"
else
  cp "$tpl/agent-validate.groovy" "$path/ci/jenkins/agent-validate.groovy"
  echo "added ci/jenkins/agent-validate.groovy (template)"
  todo+=("edit $path/ci/jenkins/agent-validate.groovy to run this repo's real build/test/lint")
fi

# 4. CLAUDE.md (spec-kit's context_file; import AGENTS.md when that's the real one)
if [ -f "$path/CLAUDE.md" ]; then
  echo "ok    CLAUDE.md present"
elif [ -f "$path/AGENTS.md" ]; then
  printf '# Project context for Claude\n\n@AGENTS.md\n' > "$path/CLAUDE.md"
  echo "added CLAUDE.md (imports AGENTS.md)"
else
  todo+=("add a CLAUDE.md (run /init in Claude Code)")
fi

# 5. allowlist (this localsetup checkout)
if jq -e --arg r "$repo" '.repos | keys | map(ascii_downcase) | index($r | ascii_downcase)' "$config" >/dev/null; then
  echo "ok    $repo already allowlisted"
else
  tmp=$(mktemp)
  jq --arg r "$repo" --arg i "$image" '.repos[$r] = {image: $i}' "$config" > "$tmp" && mv "$tmp" "$config"
  echo "added $repo to $config (image $image)"
  todo+=("commit + merge the localsetup config.json change (shared library loads from main)")
fi

# 6. link the repo to the Project (needs: gh auth refresh -s project)
number=$(jq -r '.project.number' "$config")
owner=$(jq -r '.project.owner' "$config")
if [ "$number" = "0" ]; then
  todo+=("set project.number in $config (docs/AGENT-PIPELINE.md § Board setup)")
elif gh project link "$number" --owner "$owner" --repo "$repo" >/dev/null 2>&1; then
  echo "ok    linked $repo to project $owner#$number"
else
  todo+=("link the repo to the project: gh auth refresh -s project && gh project link $number --owner $owner --repo $repo")
fi

# 7. Jenkins GitHub App must be installed on the repo (checkout, push, PR, issue comments)
todo+=("confirm the chadrbean-jenkins GitHub App is installed on $repo with contents/issues/pull-requests: write")

echo
echo "Remaining steps:"
for t in "${todo[@]}"; do echo "  - $t"; done
