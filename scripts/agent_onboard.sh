#!/usr/bin/env bash
# Onboard a repo to the agent feature pipeline (docs/AGENT-PIPELINE.md § Onboarding).
#   scripts/agent_onboard.sh <owner/repo> <path-to-local-checkout> [image] [board-number]
# Idempotent. Checks the repo contract, scaffolds what's missing (never overwrites), adds
# the repo to the dispatcher allowlist and its board to `projects` in this checkout, and
# links the repo to that board. board-number = N from github.com/users/<owner>/projects/N.
# It does NOT commit or push anything: review, then commit in both repos yourself.
set -euo pipefail

usage='usage: agent_onboard.sh <owner/repo> <local-path> [image] [board-number]'
repo=${1:?$usage}
path=${2:?$usage}
image=${3:-localhost/ci-claude:1}
board=${4:-}
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

# 6. the repo's board: in config.json projects, and linked to the repo (needs: gh auth refresh -s project)
owner=${repo%%/*}
if [ -z "$board" ]; then
  todo+=("pick the repo's board (gh project list --owner $owner) and re-run with its number as the 4th argument")
else
  if jq -e --argjson n "$board" --arg o "$owner" '.projects | map(select(.number == $n and (.owner | ascii_downcase) == ($o | ascii_downcase))) | length > 0' "$config" >/dev/null; then
    echo "ok    project $owner#$board already in config.json"
  else
    title=$(gh project view "$board" --owner "$owner" --format json --jq .title 2>/dev/null || echo "$repo")
    tmp=$(mktemp)
    jq --argjson n "$board" --arg o "$owner" --arg t "$title" \
      '.projects += [{title: $t, owner: $o, ownerType: "user", number: $n}]' "$config" > "$tmp" && mv "$tmp" "$config"
    echo "added project $owner#$board ('$title') to $config"
    todo+=("run board.py setup (docs/AGENT-PIPELINE.md § Board setup) to add the Stage/Run fields to the new board")
  fi
  if gh project link "$board" --owner "$owner" --repo "$repo" >/dev/null 2>&1; then
    echo "ok    linked $repo to project $owner#$board"
  else
    todo+=("link the repo to the board: gh auth refresh -s project && gh project link $board --owner $owner --repo $repo")
  fi
fi

# 7. Jenkins GitHub App must be installed on the repo (checkout, push, PR, issue comments)
todo+=("confirm the chadrbean-jenkins GitHub App is installed on $repo with contents/issues/pull-requests: write")

echo
echo "Remaining steps:"
for t in "${todo[@]}"; do echo "  - $t"; done
