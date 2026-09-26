#!/usr/bin/env bash
# Verify the automation account's sudo policy. Run as chad, no sudo needed:
#   automation/test.sh                     after install (chad may still have sudo)
#   automation/test.sh --no-chad-sudo      after Phase 3: also assert chad has no root
#
# Denials are checked with `sudo -l <command>`, which reports whether a command is allowed
# WITHOUT running it, so a wrong rule can never make this script flush a firewall or read
# a secret. The wrappers are exercised for real, but only with inputs they must refuse.
set -uo pipefail

A=(sudo -u automation sudo -n)
pass=0
fail=0

ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

allowed() { # description, command...   (runs it; must exit 0)
  local d=$1
  shift
  if "${A[@]}" "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
listed() { # command...   (allowed by policy, not run)
  if "${A[@]}" -l "$@" >/dev/null 2>&1; then ok "allowed: $*"; else bad "should be allowed: $*"; fi
}
denied() { # command...   (must NOT be allowed by policy, not run)
  if "${A[@]}" -l "$@" >/dev/null 2>&1; then bad "should be DENIED: $*"; else ok "denied: $*"; fi
}
refuses() { # description, expected exit code, command...   (wrapper must refuse)
  local d=$1 want=$2 rc
  shift 2
  "${A[@]}" "$@" >/dev/null 2>&1
  rc=$?
  if [[ $rc -eq $want ]]; then ok "$d"; else bad "$d (exit $rc, wanted $want)"; fi
}

echo "== Tier 1: root-only reads"
allowed "nft f2b table"          /usr/sbin/nft list table inet f2b-table
allowed "fail2ban status"        /usr/bin/fail2ban-client status
allowed "fail2ban sshd jail"     /usr/bin/fail2ban-client status sshd
allowed "sshd -T"                /usr/sbin/sshd -T
allowed "sshd -t"                /usr/sbin/sshd -t
allowed "ss listeners"           /usr/bin/ss -tlnp
allowed "systemd status ssh"     /usr/bin/systemctl --no-pager status ssh
allowed "systemd failed units"   /usr/bin/systemctl --no-pager list-units --failed

echo "== Logs without sudo (adm group)"
if sudo -u automation /usr/bin/journalctl --no-pager -n 1 >/dev/null 2>&1; then ok "automation reads the journal"; else bad "automation cannot read the journal"; fi
if sudo -u automation /usr/bin/tail -n 1 /var/log/fail2ban.log >/dev/null 2>&1; then ok "automation reads /var/log/fail2ban.log"; else bad "automation cannot read /var/log/fail2ban.log"; fi
if sudo -u automation /usr/bin/tail -n 1 /var/log/auth.log >/dev/null 2>&1; then ok "automation reads /var/log/auth.log"; else bad "automation cannot read /var/log/auth.log"; fi

echo "== Discovery wrapper (host-read)"
H=/usr/local/sbin/host-read
allowed "host-read cat"          "$H" cat /etc/hostname
allowed "host-read grep -r"      "$H" grep -rn PermitRootLogin /etc/ssh
allowed "host-read find"         "$H" find /var/log -maxdepth 1 -name 'fail2ban*'
allowed "host-read ls"           "$H" ls -la /etc/sudoers.d
allowed "host-read read sudoers" "$H" cat /etc/sudoers.d/automation
refuses "host-read refuses shadow"       3 "$H" cat /etc/shadow
refuses "host-read refuses ssh host key" 3 "$H" cat /etc/ssh/ssh_host_ed25519_key
refuses "host-read refuses /root"        3 "$H" ls /root
refuses "host-read refuses /home"        3 "$H" cat /home/chad/.bashrc
refuses "host-read refuses find -exec"   2 "$H" find /etc -exec id '{}' ';'
refuses "host-read refuses find -delete" 2 "$H" find /var/log -delete
refuses "host-read refuses grep -f"      2 "$H" grep -f /etc/hostname x /etc/hostname
refuses "host-read refuses ../ escape"   3 "$H" cat /etc/../etc/shadow

echo "== Tier 2: service control (policy only, not run)"
listed /usr/bin/systemctl reload ssh
listed /usr/bin/systemctl restart fail2ban
listed /usr/bin/systemctl restart fail2ban-exporter
listed /usr/bin/systemctl daemon-reload
listed /usr/local/sbin/f2b-unban 192.0.2.1
refuses "f2b-unban refuses non-IP"       64 /usr/local/sbin/f2b-unban 'x; id'

echo "== Tier 3: deploy and repo housekeeping"
allowed "host-deploy --list"     /usr/local/sbin/host-deploy --list
refuses "host-deploy unknown item" 1 /usr/local/sbin/host-deploy no-such-item
allowed "host-repo scan"         /usr/local/sbin/host-repo scan /home/chad/git/localsetup
refuses "host-repo refuses /etc"         3 /usr/local/sbin/host-repo rm /etc/hostname
refuses "host-repo refuses top-level rm" 3 /usr/local/sbin/host-repo rm /home/chad/git/localsetup

echo "== Must be denied (policy check, never run)"
denied /bin/bash
denied /usr/bin/bash -c id
denied /bin/sh
denied /usr/bin/cat /etc/shadow
denied /usr/bin/grep root /etc/shadow
denied /usr/bin/find /etc -exec id '{}' ';'
denied /usr/bin/python3 -c 'import os'
denied /usr/bin/vi /etc/passwd
denied /usr/bin/less /etc/passwd
denied /usr/sbin/visudo
denied /usr/bin/su
denied /usr/bin/systemctl edit ssh
denied /usr/bin/systemctl restart cron
denied /usr/bin/systemctl stop fail2ban
denied /usr/bin/systemctl --no-pager status cron
denied /usr/bin/install -m 4755 /bin/sh /usr/local/bin/x
denied /usr/bin/cp /etc/passwd /tmp/x
denied /usr/bin/chown chad /etc/shadow
denied /usr/bin/rm -rf /etc
denied /usr/bin/apt install nmap
denied /usr/sbin/nft flush ruleset
denied /usr/bin/podman ps
denied /usr/sbin/useradd x
denied /usr/bin/passwd root

if [[ ${1:-} == --no-chad-sudo ]]; then
  echo "== chad must have no root of his own"
  if sudo -n true >/dev/null 2>&1; then bad "chad can still sudo"; else ok "chad has no sudo"; fi
  if id -nG chad | tr ' ' '\n' | grep -qxE 'sudo|lxd'; then bad "chad still in sudo/lxd group"; else ok "chad not in sudo or lxd"; fi
  if id -nG chad | tr ' ' '\n' | grep -qx adm; then ok "chad keeps adm (logs)"; else bad "chad lost adm (cannot read logs)"; fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
