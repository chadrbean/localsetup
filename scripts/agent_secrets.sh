#!/usr/bin/env bash
# Put the agent feature pipeline's two tokens into jenkins/.env (docs/AGENT-PIPELINE.md § One-time setup).
# Run it yourself in a terminal: it prompts, never echoes, and checks each token before saving.
#   scripts/agent_secrets.sh [path/to/jenkins/.env]     (default: ~/git/localsetup/jenkins/.env)
#
#   AGENT_CLAUDE_OAUTH_TOKEN  run `claude setup-token` in another terminal and paste what it prints
#   AGENT_GH_PROJECT_PAT      classic PAT, scopes project + repo:
#                             https://github.com/settings/tokens/new?scopes=project,repo&description=jenkins-agent-pipeline
# Then apply with: cd ~/git/localsetup/jenkins && podman-compose up -d
set -euo pipefail

env_file=${1:-$HOME/git/localsetup/jenkins/.env}
[ -f "$env_file" ] || { echo "no such file: $env_file" >&2; exit 1; }

# set_key KEY VALUE: replace or append KEY=VALUE, keep the file mode 600.
set_key() {
  local key=$1 value=$2 tmp
  tmp=$(mktemp)
  grep -v "^${key}=" "$env_file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$env_file" && rm -f "$tmp"
  chmod 600 "$env_file"
}

echo "1/2  GitHub classic PAT (scopes: project, repo)"
echo "     create: https://github.com/settings/tokens/new?scopes=project,repo&description=jenkins-agent-pipeline"
read -rsp "     paste token: " pat; echo
scopes=$(curl -fsS -o /dev/null -D - -H "Authorization: token $pat" https://api.github.com/user \
         | tr -d '\r' | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: //p')
case ",${scopes// /}," in
  *,project,*) ;;
  *) echo "     token scopes are '$scopes' — needs project (and repo). Not saved." >&2; exit 1 ;;
esac
case ",${scopes// /}," in *,repo,*) ;; *) echo "     warning: no 'repo' scope ($scopes)";; esac
set_key AGENT_GH_PROJECT_PAT "$pat"
echo "     saved (scopes: $scopes)"

echo
echo "2/2  Claude Code OAuth token: run 'claude setup-token' in another terminal, then paste it here"
read -rsp "     paste token: " tok; echo
if podman image exists localhost/ci-claude:1; then
  # Judge the structured result, not the text: an auth failure still prints a "result" event,
  # with is_error=true and a message that can contain "ok" inside words like "token".
  verdict=$(podman run --rm -u 0:0 -e IS_SANDBOX=1 -e CLAUDE_CODE_OAUTH_TOKEN="$tok" localhost/ci-claude:1 \
              claude -p --output-format json --max-turns 1 "Reply with exactly: ok" 2>/dev/null \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if not d.get("is_error") and d.get("result","").strip().lower().rstrip(".") == "ok" else "bad")' 2>/dev/null)
  if [ "$verdict" = "ok" ]; then
    echo "     token works (headless claude -p in localhost/ci-claude:1)"
  else
    echo "     token did NOT work in localhost/ci-claude:1 — not saved." >&2; exit 1
  fi
else
  echo "     (localhost/ci-claude:1 not built; skipped the live check)"
fi
set_key AGENT_CLAUDE_OAUTH_TOKEN "$tok"
echo "     saved"

echo
echo "Done: $env_file. Apply with:  cd $(dirname "$env_file") && podman-compose up -d"
