#!/usr/bin/env bash
# Install (or update) the `automation` account, its sudo rules and the root wrappers.
# ADMIN ONLY: run as root, e.g. `su -` then this script. Claude never runs or edits it.
#
#   automation/install.sh            account, groups, wrappers, manifest, sudoers
#   automation/install.sh key        create the read-only deploy key, print its public half
#   automation/install.sh clone      clone /opt/localsetup with that key (after adding it on GitHub)
#
# Safe to re-run. Every sudoers file is validated with BOTH engines on this host (classic
# visudo and sudo-rs visudo) before it is put in place, and removed again if the combined
# config no longer parses. Prefer running it from the root-owned clone
# (/opt/localsetup/automation/install.sh) after `git -C /opt/localsetup pull`: a checkout
# under /home/chad is writable by chad, so it could change between review and run.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_URL="git@github.com:chadrbean/localsetup.git"
VISUDO_CLASSIC=/usr/sbin/visudo
VISUDO_RS=/usr/lib/cargo/bin/visudo
STATE=/etc/host-deploy

die() { echo "install.sh: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root (su -), not through sudo from the agent account"

cmd=${1:-install}

case $cmd in
  key)
    install -d -m 0755 -o root -g root "$STATE"
    if [[ ! -f $STATE/deploy_key ]]; then
      ssh-keygen -q -t ed25519 -N '' -C "host-deploy@$(hostname)" -f "$STATE/deploy_key"
      chmod 0600 "$STATE/deploy_key"
    fi
    ssh-keyscan -t ed25519 github.com 2>/dev/null >"$STATE/known_hosts"
    echo "Add this as a READ-ONLY deploy key (repo Settings > Deploy keys, leave 'write' unticked):"
    cat "$STATE/deploy_key.pub"
    echo "Compare this host key with https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints :"
    ssh-keygen -lf "$STATE/known_hosts"
    exit 0
    ;;
  clone)
    [[ -f $STATE/deploy_key ]] || die "run 'install.sh key' first and add the key on GitHub"
    [[ ! -e /opt/localsetup ]] || die "/opt/localsetup already exists"
    GIT_SSH_COMMAND="ssh -i $STATE/deploy_key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$STATE/known_hosts" \
      git clone --quiet "$REPO_URL" /opt/localsetup
    chown -R root:root /opt/localsetup
    chmod 0755 /opt/localsetup
    echo "cloned to /opt/localsetup (root-owned). Try: /usr/local/sbin/host-deploy --list"
    exit 0
    ;;
  install) ;;
  *) die "usage: install.sh [key|clone]" ;;
esac

for f in "$VISUDO_CLASSIC" "$VISUDO_RS"; do
  [[ -x $f ]] || echo "install.sh: note: $f not found, skipping that engine's check" >&2
done

check_sudoers() { # file
  local f=$1 engine
  for engine in "$VISUDO_CLASSIC" "$VISUDO_RS"; do
    if [[ -x $engine ]]; then
      "$engine" -cf "$f" >/dev/null || die "$f rejected by $engine"
    fi
  done
}

# 1. Validate before touching anything.
for f in "$HERE"/sudoers.d/*; do check_sudoers "$f"; done
python3 -I -c 'import ast,sys; [ast.parse(open(p).read()) for p in sys.argv[1:]]' \
  "$HERE/host-read.py" "$HERE/host-repo.py"
bash -n "$HERE/host-deploy.sh"
bash -n "$HERE/f2b-unban.sh"

# 2. Account: no password, no login shell, no SSH keys (sshd also has DenyUsers automation).
if ! id automation >/dev/null 2>&1; then
  useradd --create-home --shell /usr/sbin/nologin --comment "Claude scoped automation (sudo -u automation)" automation
fi
passwd -l automation >/dev/null
usermod -aG adm automation   # read the journal and /var/log without any sudo rule

# 3. Root-owned wrappers and manifest.
install -m 0755 -o root -g root "$HERE/host-deploy.sh" /usr/local/sbin/host-deploy
install -m 0755 -o root -g root "$HERE/f2b-unban.sh" /usr/local/sbin/f2b-unban
install -m 0755 -o root -g root "$HERE/host-read.py" /usr/local/sbin/host-read
install -m 0755 -o root -g root "$HERE/host-repo.py" /usr/local/sbin/host-repo
install -d -m 0755 -o root -g root "$STATE"
install -m 0644 -o root -g root "$HERE/host-deploy.manifest" "$STATE/manifest"
if [[ ! -f $STATE/host-deploy.conf ]]; then
  cat >"$STATE/host-deploy.conf" <<'EOF'
# host-deploy settings (root-owned). Set REQUIRE_SIGNED=1 once GitHub's web-flow public key is
# in /etc/host-deploy/gnupg (automation/README.md), so only GitHub-made merge commits deploy.
REQUIRE_SIGNED=0
EOF
  chmod 0644 "$STATE/host-deploy.conf"
fi

# 4. Sudoers: stage under a name sudo ignores (contains a dot), validate, then move into place.
declare -A backup=()
place() { # name
  local name=$1 dest=/etc/sudoers.d/$1
  if [[ -f $dest ]]; then backup[$name]=$(mktemp); cp -p "$dest" "${backup[$name]}"; fi
  install -m 0440 -o root -g root "$HERE/sudoers.d/$name" "$dest.staged"
  check_sudoers "$dest.staged"
  mv -f "$dest.staged" "$dest"
}
undo() {
  local name
  for name in automation 10-chad-to-automation; do
    if [[ -n ${backup[$name]:-} ]]; then mv -f "${backup[$name]}" "/etc/sudoers.d/$name"; else rm -f "/etc/sudoers.d/$name"; fi
  done
}
place automation
place 10-chad-to-automation
for engine in "$VISUDO_CLASSIC" "$VISUDO_RS"; do
  if [[ -x $engine ]] && ! "$engine" -c >/dev/null; then
    undo
    die "combined sudoers rejected by $engine, previous files restored"
  fi
done
for name in "${!backup[@]}"; do rm -f "${backup[$name]}"; done

echo "installed. Next:"
echo "  as chad: automation/test.sh"
[[ -d /opt/localsetup ]] || echo "  one-time: install.sh key, add the key on GitHub, install.sh clone (enables host-deploy)"
