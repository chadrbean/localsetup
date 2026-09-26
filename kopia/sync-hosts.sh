#!/usr/bin/env bash
# Keep both desktops' Kopia config identical to this repo.
#
#   kopia/sync-hosts.sh check   report drift (ignore file + policies), change nothing
#   kopia/sync-hosts.sh push    install kopia/.kopiaignore on both hosts, then check
#
# Hosts: this machine (wkspikaoschad, /home/chad; ~/.kopiaignore is a hardlink to
# kopia/.kopiaignore) and Zuriel's (wkspikaoszuriel, SSH host "zuriel", plain copy).
# Policies are compared against kopia/policies/*.json; the per-host home policy is
# compared with its source key stripped.
set -euo pipefail

cd "$(dirname "$0")"
REMOTE=${KOPIA_REMOTE_HOST:-zuriel}
# Use the key file from ~/.ssh/config directly: the desktop SSH agent can refuse to
# sign non-interactively ("agent refused operation").
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o IdentityAgent=none -o IdentitiesOnly=yes)
KOPIA='/opt/KopiaUI/resources/server/kopia --config-file "$HOME/.config/kopia/repository.config"'

remote() { ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"; }

# Strip the {"<source>": ...} wrapper so policies from different hosts compare equal.
norm_policy() { python3 -c 'import json,sys; print(json.dumps(next(iter(json.load(sys.stdin).values())), sort_keys=True))'; }

check() {
    local rc=0 want local_sum remote_sum
    want=$(md5sum < .kopiaignore | cut -d' ' -f1)
    local_sum=$(md5sum < "$HOME/.kopiaignore" | cut -d' ' -f1)
    remote_sum=$(remote 'md5sum < ~/.kopiaignore' | cut -d' ' -f1)
    [ "$local_sum" = "$want" ] && echo "ok    local  .kopiaignore" || { echo "DRIFT local  .kopiaignore"; rc=1; }
    [ "$remote_sum" = "$want" ] && echo "ok    $REMOTE .kopiaignore" || { echo "DRIFT $REMOTE .kopiaignore"; rc=1; }
    [ "$(stat -c %i "$HOME/.kopiaignore")" = "$(stat -c %i .kopiaignore)" ] \
        || echo "warn  local ~/.kopiaignore is not hardlinked to the repo file (ln -f)"

    local g_want h_want g_remote h_remote
    g_want=$(norm_policy < policies/global.json)
    h_want=$(norm_policy < policies/home-chad.json)
    # shellcheck disable=SC2016  # expanded on the remote host
    g_remote=$(remote "$KOPIA policy export --global" | norm_policy)
    # shellcheck disable=SC2016
    h_remote=$(remote "$KOPIA"' policy export "$(whoami)@$(hostname):$HOME"' | norm_policy)
    [ "$g_remote" = "$g_want" ] && echo "ok    $REMOTE global policy" || { echo "DRIFT $REMOTE global policy"; diff <(tr ',' '\n' <<<"$g_want") <(tr ',' '\n' <<<"$g_remote") || true; rc=1; }
    [ "$h_remote" = "$h_want" ] && echo "ok    $REMOTE home policy" || { echo "DRIFT $REMOTE home policy"; rc=1; }
    return $rc
}

push() {
    # cp (not mv/ln) writes into the existing inode, so the hardlink survives.
    cp .kopiaignore "$HOME/.kopiaignore"
    # -n: never overwrite an earlier backup (a second push the same day would
    # otherwise replace the pre-change copy with the new file).
    # shellcheck disable=SC2016  # expanded on the remote host
    remote 'cp -np ~/.kopiaignore ~/.kopiaignore.bak-$(date +%F) 2>/dev/null || true'
    scp -q "${SSH_OPTS[@]}" .kopiaignore "$REMOTE:.kopiaignore"
    echo "pushed .kopiaignore (remote pre-change backup: ~/.kopiaignore.bak-$(date +%F))"
    check
}

case "${1:-check}" in
    check) check ;;
    push) push ;;
    *) echo "usage: $0 [check|push]" >&2; exit 2 ;;
esac
