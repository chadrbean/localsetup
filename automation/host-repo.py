#!/usr/bin/python3 -I
"""host-repo: root housekeeping inside /home/chad/git for the `automation` account.

Installed root:root 0755 at /usr/local/sbin/host-repo and run as
    sudo -u automation sudo -n /usr/local/sbin/host-repo <command> <path>

Commands:
    scan  [path]   list entries under path not owned by chad (default: all of /home/chad/git)
    chown <path>   give chad:chad ownership of path and everything below it
    rm    <path>   remove path recursively (at least two levels below /home/chad/git)

Why this exists: chad owns the whole tree, so the only root work needed there is
cleaning up files a container runtime left owned by a sub-uid. Granting "all sudo in
/home/chad/git" would be root: chad can edit anything in that tree, so any script or
symlink in it would run as root. So this tool never executes anything from the tree
and never follows a symlink: every path component is opened with O_NOFOLLOW starting
from the /home/chad/git directory descriptor, entries on other filesystems are skipped,
and regular files with more than one hard link are left alone (chowning one would
change the other name, e.g. a link to a system file).
"""
import os
import pwd
import stat
import sys
import syslog

ROOT = "/home/chad/git"
OWNER = "chad"
SCAN_LIMIT = 500


def die(msg, code=2):
    sys.stderr.write("host-repo: %s\n" % msg)
    sys.exit(code)


def components(path):
    if not path or "\0" in path or not os.path.isabs(path):
        die("an absolute path is required")
    norm = os.path.normpath(path)
    if norm != ROOT and not norm.startswith(ROOT + "/"):
        die("%s is outside %s" % (path, ROOT), 3)
    return [c for c in norm[len(ROOT):].split("/") if c]


def open_dir(name, dir_fd):
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)


def walk_to(parts):
    """Return (parent dir fd, final name, root st_dev); parent is opened without following symlinks."""
    fd = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    dev = os.fstat(fd).st_dev
    try:
        for part in parts[:-1]:
            nxt = open_dir(part, fd)
            os.close(fd)
            fd = nxt
    except OSError as exc:
        os.close(fd)
        die("%s: %s (symlinks are never followed)" % (part, exc.strerror))
    return fd, (parts[-1] if parts else None), dev


def chown_tree(dirfd, name, uid, gid, dev):
    st = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    if st.st_dev != dev:
        sys.stderr.write("skip (other filesystem): %s\n" % name)
        return
    if stat.S_ISREG(st.st_mode) and st.st_nlink > 1:
        sys.stderr.write("skip (hard-linked file): %s\n" % name)
        return
    os.chown(name, uid, gid, dir_fd=dirfd, follow_symlinks=False)
    if stat.S_ISDIR(st.st_mode):
        sub = open_dir(name, dirfd)
        try:
            for entry in os.listdir(sub):
                chown_tree(sub, entry, uid, gid, dev)
        finally:
            os.close(sub)


def remove_tree(dirfd, name, dev):
    st = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    if not stat.S_ISDIR(st.st_mode):
        os.unlink(name, dir_fd=dirfd)
        return
    if st.st_dev != dev:
        die("%s is on another filesystem, not removing" % name, 3)
    sub = open_dir(name, dirfd)
    try:
        for entry in os.listdir(sub):
            remove_tree(sub, entry, dev)
    finally:
        os.close(sub)
    os.rmdir(name, dir_fd=dirfd)


def scan(dirfd, uid, prefix, shown):
    for entry in os.listdir(dirfd):
        st = os.stat(entry, dir_fd=dirfd, follow_symlinks=False)
        full = prefix + "/" + entry
        if st.st_uid != uid:
            if shown[0] < SCAN_LIMIT:
                print("%d:%d %04o %s" % (st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode), full))
            shown[0] += 1
        if stat.S_ISDIR(st.st_mode):
            try:
                sub = open_dir(entry, dirfd)
            except OSError:
                continue
            try:
                scan(sub, uid, full, shown)
            finally:
                os.close(sub)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("scan", "chown", "rm") or len(sys.argv) > 3:
        die("usage: host-repo scan [path] | chown <path> | rm <path>", 64)
    cmd = sys.argv[1]
    path = sys.argv[2] if len(sys.argv) == 3 else (ROOT if cmd == "scan" else "")
    parts = components(path)
    syslog.openlog("host-repo", 0, syslog.LOG_AUTH)
    syslog.syslog(syslog.LOG_NOTICE, "%s %s" % (cmd, path))
    pw = pwd.getpwnam(OWNER)

    if cmd == "scan":
        fd = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            for part in parts:
                nxt = open_dir(part, fd)
                os.close(fd)
                fd = nxt
        except OSError as exc:
            die("%s: %s (symlinks are never followed)" % (path, exc.strerror))
        shown = [0]
        scan(fd, pw.pw_uid, ROOT + ("/" + "/".join(parts) if parts else ""), shown)
        if shown[0] > SCAN_LIMIT:
            print("... %d more" % (shown[0] - SCAN_LIMIT))
        return

    if not parts:
        die("refusing to act on %s itself" % ROOT, 3)
    if cmd == "rm" and len(parts) < 2:
        die("rm needs a path inside a repo, not a top-level directory of %s" % ROOT, 3)
    fd, name, dev = walk_to(parts)
    try:
        if cmd == "chown":
            chown_tree(fd, name, pw.pw_uid, pw.pw_gid, dev)
        else:
            remove_tree(fd, name, dev)
    except OSError as exc:
        die("%s: %s" % (path, exc.strerror))
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
