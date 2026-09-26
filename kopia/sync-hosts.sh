#!/usr/bin/env bash
# Keep both desktops' Kopia config identical to this repo.
#
#   kopia/sync-hosts.sh check   report drift (ignore file, autostart, policies,
#                               ses-email profile), change nothing
#   kopia/sync-hosts.sh push    install kopia/.kopiaignore on both hosts and the
#                               autostart entry on the remote, then check
#   kopia/sync-hosts.sh email   (re)create the remote ses-email notification profile
#                               from monitoring/.env (creds go over ssh stdin)
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
AUTOSTART=.config/autostart/kopia-ui.desktop
MAIL_FROM=${KOPIA_MAIL_FROM:-kopia@chadrbean.com}

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

    local a_want
    a_want=$(md5sum < kopia-ui-autostart.desktop | cut -d' ' -f1)
    [ "$(md5sum < "$HOME/$AUTOSTART" | cut -d' ' -f1)" = "$a_want" ] \
        && echo "ok    local  autostart" || { echo "DRIFT local  autostart"; rc=1; }
    [ "$(remote "md5sum < ~/$AUTOSTART" | cut -d' ' -f1)" = "$a_want" ] \
        && echo "ok    $REMOTE autostart" || { echo "DRIFT $REMOTE autostart (push)"; rc=1; }

    bash -c "$KOPIA notification profile list" 2>/dev/null | grep -q '"ses-email"' \
        && echo "ok    local  ses-email profile" || { echo "MISSING local  ses-email profile (kopia/README.md)"; rc=1; }
    remote "$KOPIA notification profile list" 2>/dev/null | grep -q '"ses-email"' \
        && echo "ok    $REMOTE ses-email profile" || { echo "MISSING $REMOTE ses-email profile ($0 email)"; rc=1; }

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
    # The autostart entry caps KopiaUI's log dirs; it takes effect at the next login.
    # Backups live outside autostart/ so the desktop doesn't launch them too.
    # shellcheck disable=SC2016
    remote 'mkdir -p ~/.config/autostart && cp -np ~/'"$AUTOSTART"' ~/.config/kopia-ui.desktop.bak-$(date +%F) 2>/dev/null || true'
    scp -q "${SSH_OPTS[@]}" kopia-ui-autostart.desktop "$REMOTE:$AUTOSTART"
    echo "pushed $AUTOSTART"
    check
}

# Same SES settings as this host's profile (kopia/README.md). The SMTP creds are the
# Terraform-managed hermes-ses-email user in monitoring/.env. They're piped to the
# remote over stdin so they never appear in a command line.
email() {
    local env=${MONITORING_ENV:-../monitoring/.env}
    [ -r "$env" ] || { echo "no $env (run from the main checkout or set MONITORING_ENV)" >&2; return 1; }
    get() { grep -E "^$1=" "$env" | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'; }
    # shellcheck disable=SC2016  # expanded on the remote host
    printf '%s\n' "$(get GRAFANA_SMTP_USER)" "$(get GRAFANA_SMTP_PASSWORD)" "$MAIL_FROM" "$(get ALERT_EMAIL_TO)" \
        | remote 'read -r U; read -r P; read -r F; read -r T; '"$KOPIA"' notification profile configure email \
            --profile-name=ses-email --smtp-server=email-smtp.us-west-2.amazonaws.com --smtp-port=587 \
            --smtp-username="$U" --smtp-password="$P" --mail-from="$F" --mail-to="$T" \
            --format=html --min-severity=warning --send-test-notification'
}

case "${1:-check}" in
    check) check ;;
    push) push ;;
    email) email ;;
    *) echo "usage: $0 [check|push|email]" >&2; exit 2 ;;
esac
