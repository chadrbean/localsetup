#!/usr/bin/env bash
# host-deploy: install reviewed, merged repo files onto this host as root.
#
# Installed root:root 0755 at /usr/local/sbin/host-deploy (automation/install.sh) and run as
#   sudo -u automation sudo -n /usr/local/sbin/host-deploy [--dry-run] <item>
#   sudo -u automation sudo -n /usr/local/sbin/host-deploy --list | --check
#
# What it does: sync the root-owned clone /opt/localsetup to origin/main, then install ONLY
# the files the ROOT-OWNED manifest /etc/host-deploy/manifest lists for <item>, to the
# destinations listed there, with a named validator and a named reload. Nothing is taken
# from the caller's checkout or environment, so a root-effective change needs a merged PR
# (and, once /etc/host-deploy/host-deploy.conf sets REQUIRE_SIGNED=1, a GitHub-signed merge
# commit). Widening the manifest is an admin action (`su -`, automation/install.sh).
#
# Manifest line:  item  source-in-clone  destination  mode  validator  reload
#   validators: none sshd-t fail2ban-t nft-c
#   reloads:    none reload-ssh restart-fail2ban restart-fail2ban-exporter
#               restart-monitoring-lan-firewall sysctl-system
set -euo pipefail
umask 022
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset BASH_ENV ENV

CONF=/etc/host-deploy/host-deploy.conf
MANIFEST=/etc/host-deploy/manifest
CLONE=/opt/localsetup
BRANCH=main
DEPLOY_KEY=/etc/host-deploy/deploy_key
KNOWN_HOSTS=/etc/host-deploy/known_hosts
GNUPGHOME_DIR=/etc/host-deploy/gnupg
REQUIRE_SIGNED=0
LOCK=/run/host-deploy.lock

die() { echo "host-deploy: $*" >&2; exit 1; }
say() { echo "host-deploy: $*"; }

root_owned() { # file must be owned by root and not group/other writable
  local owner mode
  owner=$(stat -c '%u' "$1") || die "cannot stat $1"
  mode=$(stat -c '%a' "$1")
  [[ $owner == 0 ]] || die "$1 is not owned by root"
  [[ ${mode: -2:1} != [2367] && ${mode: -1} != [2367] ]] || die "$1 is group/world writable"
}

[[ $EUID -eq 0 ]] || die "must run as root (through sudo)"
[[ -f $MANIFEST ]] || die "missing $MANIFEST (run automation/install.sh)"
root_owned "$MANIFEST"
if [[ -f $CONF ]]; then
  root_owned "$CONF"
  # shellcheck source=/dev/null
  source "$CONF"
fi

dry=0
case ${1:-} in
  --dry-run) dry=1; shift ;;
esac
[[ $# -eq 1 ]] || die "usage: host-deploy [--dry-run] <item> | --list | --check"
arg=$1

manifest_rows() { awk '!/^[[:space:]]*(#|$)/ {print}' "$MANIFEST"; }

if [[ $arg == --list ]]; then
  manifest_rows | awk '{print $1 "\t" $3}'
  exit 0
fi

sync_clone() {
  [[ -d $CLONE/.git ]] || die "no clone at $CLONE (see automation/README.md, one-time setup)"
  root_owned "$CLONE"
  export GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"
  git -C "$CLONE" fetch --quiet origin "$BRANCH"
  git -C "$CLONE" reset --quiet --hard "origin/$BRANCH"
  git -C "$CLONE" clean --quiet -fdx
  COMMIT=$(git -C "$CLONE" rev-parse HEAD)
  if [[ $REQUIRE_SIGNED == 1 ]]; then
    local status
    status=$(GNUPGHOME=$GNUPGHOME_DIR git -C "$CLONE" log -1 --format=%G? HEAD)
    [[ $status == G || $status == U ]] || die "HEAD $COMMIT has no valid GitHub signature (status '$status')"
  fi
  say "clone at $COMMIT"
}

check_row() { # source dest mode validator reload
  local src=$1 dest=$2 mode=$3 validator=$4 reload=$5 real
  case $src in /* | *..*) die "bad source path in manifest: $src" ;; esac
  case $dest in
    /etc/sudoers | /etc/sudoers.d/* | /etc/passwd* | /etc/shadow* | /etc/group* | /etc/gshadow* \
      | /etc/pam.d/* | /etc/pam.conf | /etc/security/* | /etc/polkit-1/* | /etc/cron* \
      | /var/spool/cron/* | /etc/ssh/sshd_config | /etc/host-deploy/* | /usr/local/sbin/* \
      | /etc/ld.so* | /etc/profile* | /root/* | /boot/*)
      die "destination is admin-only: $dest" ;;
    /etc/* | /usr/local/bin/*) ;;
    *) die "destination outside /etc and /usr/local/bin: $dest" ;;
  esac
  [[ $mode =~ ^0?[0-7]{3}$ ]] || die "bad mode (no special bits): $mode"
  case $validator in none | sshd-t | fail2ban-t | nft-c) ;; *) die "unknown validator: $validator" ;; esac
  case $reload in
    none | reload-ssh | restart-fail2ban | restart-fail2ban-exporter \
      | restart-monitoring-lan-firewall | sysctl-system) ;;
    *) die "unknown reload: $reload" ;;
  esac
  [[ -f $CLONE/$src && ! -L $CLONE/$src ]] || die "$src is not a regular file in the clone"
  real=$(realpath -e -- "$CLONE/$src")
  [[ $real == "$CLONE"/* ]] || die "$src escapes the clone"
}

run_validator() { # validator dest
  case $1 in
    none) ;;
    sshd-t) sshd -t ;;
    fail2ban-t) fail2ban-client -t >/dev/null ;;
    nft-c) nft -c -f "$2" ;;
  esac
}

run_reload() {
  case $1 in
    none) ;;
    reload-ssh) systemctl reload ssh ;;
    restart-fail2ban) systemctl restart fail2ban ;;
    restart-fail2ban-exporter) systemctl daemon-reload && systemctl restart fail2ban-exporter ;;
    restart-monitoring-lan-firewall) systemctl daemon-reload && systemctl restart monitoring-lan-firewall ;;
    sysctl-system) sysctl --system >/dev/null ;;
  esac
}

exec 9>"$LOCK"
flock -n 9 || die "another host-deploy is running"

sync_clone

drift=0
if [[ $arg == --check ]]; then
  while read -r item src dest _mode _validator _reload; do
    if ! cmp -s "$CLONE/$src" "$dest"; then
      echo "DRIFT $item $dest"
      drift=1
    fi
  done < <(manifest_rows)
  if [[ $drift -eq 0 ]]; then say "no drift at $COMMIT"; fi
  exit "$drift"
fi

[[ $arg =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "bad item name: $arg"
mapfile -t rows < <(manifest_rows | awk -v it="$arg" '$1 == it {print}')
[[ ${#rows[@]} -gt 0 ]] || die "unknown item '$arg' (host-deploy --list)"

declare -a dests=() backups=() existed=() validators=() reloads=()
for row in "${rows[@]}"; do
  read -r _item src dest mode validator reload <<<"$row"
  check_row "$src" "$dest" "$mode" "$validator" "$reload"
  if [[ $dry -eq 1 ]]; then
    say "would install $src -> $dest ($mode, validate $validator, reload $reload)"
    if [[ -f $dest ]]; then diff -u "$dest" "$CLONE/$src" || true; else say "  (new file)"; fi
  fi
  dests+=("$dest")
  validators+=("$validator:$dest")
  reloads+=("$reload")
done
if [[ $dry -eq 1 ]]; then exit 0; fi

logger -t host-deploy -p auth.notice "deploy item=$arg commit=$COMMIT invoked_by=${SUDO_USER:-root}"

rollback() {
  local i
  for i in "${!dests[@]}"; do
    if [[ ${existed[$i]:-0} == 1 ]]; then mv -f "${backups[$i]}" "${dests[$i]}"; else rm -f "${dests[$i]}"; fi
  done
}

for i in "${!rows[@]}"; do
  read -r _item src dest mode _validator _reload <<<"${rows[$i]}"
  if [[ -f $dest ]]; then
    backups[i]=$(mktemp "$dest.host-deploy-bak.XXXXXX")
    cp -p -- "$dest" "${backups[$i]}"
    existed[i]=1
  else
    existed[i]=0
  fi
  install -m "$mode" -o root -g root -- "$CLONE/$src" "$dest.host-deploy-new"
  mv -f -- "$dest.host-deploy-new" "$dest"
done

for v in "${validators[@]}"; do
  if ! run_validator "${v%%:*}" "${v#*:}"; then
    echo "host-deploy: validator ${v%%:*} failed, restoring previous files" >&2
    rollback
    exit 1
  fi
done

for i in "${!backups[@]}"; do
  if [[ ${existed[$i]} == 1 ]]; then rm -f -- "${backups[$i]}"; fi
done

declare -A seen=()
for r in "${reloads[@]}"; do
  if [[ -z ${seen[$r]:-} ]]; then
    seen[$r]=1
    run_reload "$r"
  fi
done
say "deployed $arg at $COMMIT"
