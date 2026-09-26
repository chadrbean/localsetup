# automation: least-privilege root for Claude

`chad` (the interactive account, and Claude running as chad) has **no sudo** once this is fully
rolled out. The only thing `chad` may do as another user is run commands as the unprivileged
`automation` account, and `automation` may do a fixed list of things as root.

```
chad ──sudo -u automation──▶ automation ──sudo -n <allowed command>──▶ root
       (one rule)                          (automation/sudoers.d/automation)
```

Claude's usage: `sudo -u automation sudo -n <command>`. If a command is not allowed, **stop and
ask**; never look for a way around it. The admin path for a human is `su -` (root has a password,
root SSH login is off).

## What automation can do

| Tier | Access | How |
|---|---|---|
| Logs and journal | everything in `journalctl` and `/var/log` (auth.log, fail2ban.log, syslog) | `adm` group membership: **no sudo rule needed**. `chad` keeps `adm` too |
| 1. Read and diagnose | `nft list …`, `fail2ban-client status [sshd\|grafana\|recidive]`, `banned`, `-t`, `sshd -T/-t`, `ss -tlnp/-ulnp/-tnp`, `lsof -nP -i`, `dmesg --ctime`, `systemctl --no-pager status <fixed units>`, `list-units --failed`, `list-timers`, `df -h`, `du -xsh /var/log\|/var/lib` | exact command lines in `sudoers.d/automation` |
| 1b. Discovery (`grep`, `cat`, `find`, `ls`, `stat`, `head`, `tail`, `wc`, `file`, `du`, `readlink`) | read anything under `/var/log /etc /opt /usr/local`, `/proc`, `/sys` and a few `/var/lib` dirs, **except** secrets | `host-read <tool> …` (`host-read.py`) |
| 2. Service control | `systemctl reload ssh`, `restart\|reload fail2ban`, `restart fail2ban-exporter`, `restart monitoring-lan-firewall`, `daemon-reload`, `enable\|disable --now sslh` (rollback only) | exact command lines |
| 2b. Unban | one IP in all jails | `f2b-unban <ip>` |
| 3. Deploy | install the files in `host-deploy.manifest` from a root-owned clone of merged `main` | `host-deploy [--dry-run] <item>`, `--list`, `--check` (drift) |
| 3b. Repo housekeeping | `scan`, `chown`, `rm` inside `/home/chad/git` (files a container left owned by a sub-uid) | `host-repo` |

Examples:

    sudo -u automation sudo -n /usr/local/sbin/host-read grep -rn "Failed password" /var/log/auth.log
    sudo -u automation sudo -n /usr/local/sbin/host-read find /etc -newer /etc/hostname -type f
    sudo -u automation sudo -n /usr/bin/fail2ban-client status sshd
    sudo -u automation sudo -n /usr/local/sbin/host-deploy --dry-run sshd-key-only
    sudo -u automation journalctl --no-pager -u ssh -n 50        # no root needed

### Why not `sudo cat` / `sudo grep` / `sudo find`?

Sudoers wildcards match `/` and spaces, so `cat *` cannot be limited to a directory, and
`find` can run any command (`-exec`) or write files (`-fprint`, `-delete`). Those rules would
read `/etc/shadow` and the SSH host keys and give a root shell, so `automation` would just be a
second full-root account. `host-read` allows only fixed read-only flags, resolves every path with
symlinks resolved, and only serves root-owned trees `chad` cannot modify, so a path can't be
swapped for a symlink after the check. It refuses `shadow*`, `*_key`, `id_*` (not `.pub`),
`*.key/pem/p12`, `*secret*`, `*credential*`, `private`, `gnupg`, NetworkManager `system-connections`,
`wireguard`, `openvpn`, `/proc/*/environ|mem|kcore`, `/root` and everything under `/home`.

### Why not "all sudo in /home/chad/git"?

`chad` owns and can edit every file in that tree, so root there means root everywhere: any script
under it could be run as root, and a symlink planted in it could make a root `chown`/`rm`/`cp`
follow into `/etc`. `host-repo` covers the real need (cleaning up files `chad` cannot touch):
every path component is opened with `O_NOFOLLOW` from the `/home/chad/git` descriptor, other
filesystems are skipped, hard-linked files are left alone, and nothing from the tree is ever
executed. Anything else in that directory `chad` already does as `chad`, or with
`podman unshare` for rootless container files.

## What automation can NOT do (admin only, `su -`)

`/etc/sudoers*`, `passwd`/`shadow`/`group`, PAM, polkit, cron, `apt`, new systemd units outside the
manifest, `su`, `visudo`, any shell, interpreter, editor or pager, `find/xargs/tar/rsync` with free
arguments, rootful `podman`, `/etc/hosts` (until the hairpin lines are tracked), and any file not
in `host-deploy.manifest`. `test.sh` checks the denials.

## Request more access (the monitor and adjust loop)

1. See what was tried: `journalctl _COMM=sudo --since today | grep -iE "not allowed|command not allowed|denied"`,
   `journalctl -t host-read -t host-repo -t host-deploy -t f2b-unban --since today`, and `/var/log/auth.log`.
2. Open a PR that edits `sudoers.d/automation`, a wrapper, or `host-deploy.manifest`. Keep rules to exact
   command lines. CI does not run `visudo`; `install.sh` validates with both engines before it installs.
3. The admin installs it: `su -`, `git -C /opt/localsetup pull`, `/opt/localsetup/automation/install.sh`.
   **Claude never edits or installs `automation/sudoers.d/*` on the host and never widens scope without approval.**

## Files

| File | Installed to | Purpose |
|---|---|---|
| `sudoers.d/10-chad-to-automation` | `/etc/sudoers.d/` (0440) | chad's single sudo rule: `(automation)` |
| `sudoers.d/automation` | `/etc/sudoers.d/` (0440) | automation's root rules (exact commands) |
| `host-read.py` | `/usr/local/sbin/host-read` | read-only discovery |
| `host-repo.py` | `/usr/local/sbin/host-repo` | symlink-safe root housekeeping in `/home/chad/git` |
| `host-deploy.sh` | `/usr/local/sbin/host-deploy` | manifest-only deploy from the root-owned clone |
| `host-deploy.manifest` | `/etc/host-deploy/manifest` | the items host-deploy may install |
| `f2b-unban.sh` | `/usr/local/sbin/f2b-unban` | unban one IP |
| `install.sh` | run by the admin | account, groups, wrappers, sudoers (validated with both engines) |
| `test.sh` | run as chad | positive and negative policy tests |

## One-time setup (admin)

1. `su -`, then `automation/install.sh` (account, groups, wrappers, sudoers).
2. `automation/install.sh key`: prints a public key. Add it on GitHub as a **read-only** deploy key
   (repo Settings, Deploy keys, leave "Allow write access" unticked), check the printed host-key
   fingerprint against GitHub's published one.
3. `automation/install.sh clone`: root-owned clone at `/opt/localsetup`.
4. As chad: `automation/test.sh`. Later, after chad's sudo is removed: `automation/test.sh --no-chad-sudo`.
5. Optional hardening: import GitHub's web-flow public key into `/etc/host-deploy/gnupg`, then set
   `REQUIRE_SIGNED=1` in `/etc/host-deploy/host-deploy.conf` so only GitHub-made merge commits deploy.

## Honest limits

- **Two sudo engines.** `/usr/bin/sudo` is a wrapper that runs sudo-rs unless `-A`/`-E` is used or the
  account has no password (`NP`). `automation` is locked (`L`), so sudo-rs applies. Every rule must
  parse in both engines; `install.sh` checks both.
- **Deploy is root code execution by design.** Manifest units, the sshd drop-in and `awsChadHomeIp.sh`
  run as root. The guarantee is "only reviewed content from merged `main`", not "cannot reach root".
  Free-plan private repos have no branch protection, so a stolen GitHub token could push to `main`;
  `REQUIRE_SIGNED=1` (above) closes most of that.
- **`libvirt` group stays** on `chad`, and it is root-equivalent (kept by choice, documented gap).
- **`host-read` is a deny-list for secrets** (patterns above); a secret with an unusual name inside an
  allowed root would be readable. It exists to make discovery possible, not to hide from `automation`.
- Traefik's in-memory bans are not fail2ban's: `podman restart traefik` (as chad, no sudo) clears them.
