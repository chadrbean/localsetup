#!/usr/bin/env python3
"""Parse every tracked Python, YAML and JSON file; exit 1 on the first class of errors.

Run by the localsetup/ci Jenkins job (ci/jenkins/ci.Jenkinsfile) inside ci-terraform,
which has PyYAML. Runnable locally too: python3 ci/check_syntax.py
"""
import json
import py_compile
import subprocess
import sys
import tempfile

import yaml


def tracked_files():
    out = subprocess.run(["git", "ls-files", "-z"], check=True, capture_output=True, text=True).stdout
    return [f for f in out.split("\0") if f]


def check(path, pyc):
    if path.endswith(".py"):
        py_compile.compile(path, cfile=pyc, doraise=True)
    elif path.endswith((".yml", ".yaml")):
        with open(path, encoding="utf-8") as f:
            list(yaml.safe_load_all(f))
    elif path.endswith(".json"):
        with open(path, encoding="utf-8") as f:
            json.load(f)
    else:
        return False
    return True


def main():
    checked, errors = 0, []
    with tempfile.TemporaryDirectory() as tmp:
        for path in tracked_files():
            try:
                checked += check(path, f"{tmp}/x.pyc")
            except Exception as e:  # noqa: BLE001 — any parse failure is a finding
                errors.append(f"{path}: {str(e).splitlines()[0]}")
    for e in errors:
        print(f"ERROR {e}")
    print(f"check_syntax: {checked} files, {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
