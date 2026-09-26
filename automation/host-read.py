#!/usr/bin/python3 -I
"""host-read: read-only discovery as root, for the `automation` account.

Installed root:root 0755 at /usr/local/sbin/host-read and run as
    sudo -u automation sudo -n /usr/local/sbin/host-read <tool> [args...]

Tools: cat head tail wc grep find ls stat file du readlink

Why a wrapper: `sudo cat`, `sudo grep` and `sudo find` cannot be scoped in sudoers
(wildcards match "/" and spaces), so they would read /etc/shadow and private keys, and
`find -exec` is a root shell. This wrapper allows only fixed read-only flags, resolves
every path (symlinks included) and refuses anything outside ALLOWED_ROOTS or matching
the secret deny list. Allowed roots are root-owned trees that chad cannot modify, so a
path cannot be swapped for a symlink between the check and the read. Nothing under
/home is allowed on purpose.

Widen it only by PR (automation/README.md).
"""
import fnmatch
import os
import re
import sys
import syslog

ALLOWED_ROOTS = (
    "/var/log", "/etc", "/opt", "/usr/local",
    "/var/lib/fail2ban", "/var/lib/systemd", "/var/lib/dpkg", "/var/lib/apt",
    "/var/lib/logrotate", "/proc", "/sys", "/run/systemd", "/run/fail2ban",
)

# Matched (case-insensitively) against the basename of the path and of every parent
# directory of the resolved path.
DENY_NAMES = (
    "shadow*", "gshadow*", "opasswd", "*_key", "id_*", "*.key", "*.pem", "*.p12",
    "*.pfx", "*.jks", "*.kdbx", ".netrc", ".pgpass", "*credential*", "*secret*",
    "private", "gnupg", ".gnupg", "system-connections", "wireguard", "openvpn",
    "environ", "mem", "kcore", "stack", "syscall",
)
PUBLIC_OK = (".pub",)

NUM = re.compile(r"^\d+$")
SNUM = re.compile(r"^[+-]?\d+$")
ANY = re.compile(r"^[^\0]*$")

BIN = {t: "/usr/bin/" + t for t in
       ("cat", "head", "tail", "wc", "grep", "find", "ls", "stat", "file", "du", "readlink")}


def die(msg, code=2):
    sys.stderr.write("host-read: %s\n" % msg)
    sys.exit(code)


def denied_name(name):
    low = name.lower()
    if low.endswith(PUBLIC_OK):
        return False
    return any(fnmatch.fnmatchcase(low, pat) for pat in DENY_NAMES)


def canon(path):
    if "\0" in path or not path:
        die("bad path")
    try:
        real = os.path.realpath(path, strict=True)
    except OSError as exc:
        die("%s: %s" % (path, exc.strerror or exc))
    if not any(real == r or real.startswith(r + "/") for r in ALLOWED_ROOTS):
        die("%s: outside the allowed roots (%s)" % (real, " ".join(ALLOWED_ROOTS)), 3)
    for part in real.split("/"):
        if part and denied_name(part):
            die("%s: refused (secret material)" % real, 3)
    return real


def parse(args, zero, valued, long_zero=(), long_valued=None):
    """Tiny getopt: returns (passthrough flags, positionals). Unknown flags are fatal."""
    long_valued = long_valued or {}
    out, pos, i = [], [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos += args[i + 1:]
            break
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            if name in long_zero and not eq:
                out.append(a)
            elif name in long_valued:
                if not eq:
                    i += 1
                    if i >= len(args):
                        die("%s needs a value" % name)
                    val = args[i]
                if not long_valued[name].match(val):
                    die("bad value for %s" % name)
                out.append("%s=%s" % (name, val))
            else:
                die("flag not allowed: %s" % name)
        elif a.startswith("-") and len(a) > 1:
            cluster, j = a[1:], 0
            while j < len(cluster):
                c = cluster[j]
                if c in zero:
                    out.append("-" + c)
                    j += 1
                elif c in valued:
                    val = cluster[j + 1:]
                    if not val:
                        i += 1
                        if i >= len(args):
                            die("-%s needs a value" % c)
                        val = args[i]
                    if not valued[c].match(val):
                        die("bad value for -%s" % c)
                    out += ["-" + c, val]
                    break
                else:
                    die("flag not allowed: -%s" % c)
        else:
            pos.append(a)
        i += 1
    return out, pos


def run(tool, argv):
    syslog.openlog("host-read", 0, syslog.LOG_AUTH)
    syslog.syslog(syslog.LOG_NOTICE, "run %s" % " ".join([tool] + argv)[:500])
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"}
    os.execve(BIN[tool], [tool] + argv, env)


def paths_required(pos):
    if not pos:
        die("a path is required")
    return [canon(p) for p in pos]


def do_simple(tool, zero, valued):
    flags, pos = parse(sys.argv[2:], zero, valued)
    run(tool, flags + ["--"] + paths_required(pos))


def do_grep():
    flags, pos = parse(
        sys.argv[2:], "rnivwxFEGclLoqsHhaI", {"A": NUM, "B": NUM, "C": NUM, "m": NUM, "e": ANY},
        long_valued={"--include": ANY, "--exclude": ANY, "--exclude-dir": ANY})
    if "-e" not in flags:
        if not pos:
            die("grep needs a pattern")
        flags += ["-e", pos.pop(0)]
    inject = ["--exclude=" + p for p in DENY_NAMES] + ["--exclude-dir=" + p for p in DENY_NAMES]
    run("grep", flags + inject + ["--"] + paths_required(pos))


FIND_VALUE = {
    "-name": ANY, "-iname": ANY, "-path": ANY, "-ipath": ANY, "-regex": ANY, "-iregex": ANY,
    "-type": re.compile(r"^[bcdflps]$"),
    "-mtime": SNUM, "-mmin": SNUM, "-atime": SNUM, "-amin": SNUM, "-ctime": SNUM, "-cmin": SNUM,
    "-size": re.compile(r"^[+-]?\d+[cwbkMG]?$"), "-perm": re.compile(r"^[-/]?[0-7]{1,4}$"),
    "-user": re.compile(r"^[A-Za-z0-9_.-]+$"), "-group": re.compile(r"^[A-Za-z0-9_.-]+$"),
    "-maxdepth": NUM, "-mindepth": NUM, "-links": SNUM,
}
FIND_ZERO = {"-empty", "-nouser", "-nogroup", "-print", "-print0", "-ls", "-prune", "-not",
             "!", "-a", "-o", "(", ")", "-xdev"}


def do_find():
    args, i, roots = sys.argv[2:], 0, []
    while i < len(args) and not (args[i].startswith("-") or args[i] in ("!", "(")):
        roots.append(args[i])
        i += 1
    expr = []
    while i < len(args):
        tok = args[i]
        if tok in FIND_ZERO:
            expr.append(tok)
        elif tok == "-newer":
            i += 1
            if i >= len(args):
                die("-newer needs a path")
            expr += [tok, canon(args[i])]
        elif tok in FIND_VALUE:
            i += 1
            if i >= len(args) or not FIND_VALUE[tok].match(args[i]):
                die("bad or missing value for %s" % tok)
            expr += [tok, args[i]]
        else:
            die("find primary not allowed: %s (no -exec/-delete/-fprint)" % tok)
        i += 1
    run("find", paths_required(roots) + expr)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in BIN:
        die("usage: host-read {%s} [args...]" % "|".join(sorted(BIN)), 64)
    tool = sys.argv[1]
    if tool == "grep":
        do_grep()
    elif tool == "find":
        do_find()
    elif tool == "cat":
        do_simple(tool, "nbAEsTv", {})
    elif tool in ("head", "tail"):
        do_simple(tool, "qv", {"n": SNUM, "c": SNUM})
    elif tool == "wc":
        do_simple(tool, "lwcm", {})
    elif tool == "ls":
        do_simple(tool, "laAhRd1trSFin", {})
    elif tool == "stat":
        do_simple(tool, "", {"c": ANY})
    elif tool == "file":
        do_simple(tool, "bi", {})
    elif tool == "du":
        do_simple(tool, "shacxbkm", {"d": NUM})
    elif tool == "readlink":
        do_simple(tool, "fenm", {})


if __name__ == "__main__":
    main()
