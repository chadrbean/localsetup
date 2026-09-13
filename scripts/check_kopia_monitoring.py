#!/usr/bin/env python3
"""End-to-end check of Kopia monitoring through Grafana.

Runs every query in the Kopia dashboard through Grafana's datasource API
(/api/ds/query — the same path the browser uses), checks the Kopia alert
rules evaluate without errors, and confirms the email contact point exists.
See docs/KOPIA-MONITORING.md.

Usage (from repo root):
    python3 scripts/check_kopia_monitoring.py
Env overrides: GRAFANA_URL (default http://127.0.0.1:3000), GRAFANA_ADMIN_USER,
GRAFANA_ADMIN_PASSWORD (default: read from monitoring/.env), KOPIA_DASHBOARD.
Exit code 0 = everything passed.
"""
import base64
import json
import os
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GRAFANA = os.environ.get("GRAFANA_URL", "http://127.0.0.1:3000")
DASHBOARD = Path(os.environ.get("KOPIA_DASHBOARD", ROOT / "monitoring/dashboards/kopia.json"))
CONTACT_POINT = "email-alerts"
# Panels that are healthy when empty (no errors, no retention deletes yet).
MAY_BE_EMPTY = ("error", "expired", "warnings")
# Template variables → concrete values for API queries.
VARS = {"$source": ".*", "$__auto": "5m", "$__interval": "5m", "$__range": "24h"}


def env_file_creds():
    creds = {}
    env = ROOT / "monitoring/.env"
    if env.exists():
        for line in env.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                creds[k.strip()] = v.strip()
    user = os.environ.get("GRAFANA_ADMIN_USER") or creds.get("GRAFANA_ADMIN_USER") or "admin"
    pw = os.environ.get("GRAFANA_ADMIN_PASSWORD") or creds.get("GRAFANA_ADMIN_PASSWORD")
    if not pw:
        sys.exit("GRAFANA_ADMIN_PASSWORD not set (env or monitoring/.env)")
    return user, pw


USER, PASSWORD = env_file_creds()
AUTH = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()


def api(path, body=None):
    req = urllib.request.Request(
        GRAFANA + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": AUTH, "Content-Type": "application/json"},
        method="POST" if body is not None else "GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:300]}


def panels(dash):
    for p in dash["panels"]:
        yield p
        yield from p.get("panels", [])


def frame_rows(result):
    rows = 0
    for f in result.get("frames", []):
        values = f.get("data", {}).get("values", [])
        if values:
            rows = max(rows, len(values[0]))
    return rows


def check_panels(dash):
    fails = 0
    print(f"{'PANEL':52} {'RESULT':8} DETAIL")
    for p in panels(dash):
        for t in p.get("targets", []):
            expr = t.get("expr")
            if not expr:
                continue
            for k, v in VARS.items():
                expr = expr.replace(k, v)
            q = {
                "refId": t.get("refId", "A"),
                "datasource": p.get("datasource") or {},
                "expr": expr,
                "queryType": t.get("queryType", "range"),
                "maxLines": t.get("maxLines", 100),
                "legendFormat": t.get("legendFormat", ""),
            }
            if "step" in t:
                q["step"] = t["step"]
            frm = f"now-{p['timeFrom']}" if p.get("timeFrom") else "now-24h"
            status, body = api("/api/ds/query", {"queries": [q], "from": frm, "to": "now"})
            res = body.get("results", {}).get(q["refId"], {}) if isinstance(body, dict) else {}
            err = res.get("error") or (body.get("error") if status != 200 else None)
            rows = frame_rows(res)
            title = p["title"][:52]
            if err:
                verdict, detail = "FAIL", str(err)[:120]
            elif rows == 0 and not any(w in p["title"].lower() for w in MAY_BE_EMPTY):
                verdict, detail = "EMPTY", "query ok but returned no data"
            else:
                verdict, detail = "PASS", f"{rows} rows"
            fails += verdict != "PASS"
            print(f"{title:52} {verdict:8} {detail}")
    return fails


def check_rules():
    fails = 0
    status, body = api("/api/prometheus/grafana/api/v1/rules")
    rules = [r for g in body.get("data", {}).get("groups", []) if g["name"] == "kopia" for r in g["rules"]]
    if not rules:
        print("RULES    FAIL     no rules in group 'kopia'")
        return 1
    print(f"\n{'ALERT RULE':52} {'HEALTH':8} STATE")
    for r in rules:
        bad = r.get("health") == "error" or r.get("lastError")
        fails += bool(bad)
        print(f"{r['name'][:52]:52} {r.get('health', '?'):8} {r.get('state')} {r.get('lastError', '')[:100]}")
    return fails


def check_contact_point():
    status, body = api("/api/v1/provisioning/contact-points")
    names = [c.get("name") for c in body] if isinstance(body, list) else []
    ok = CONTACT_POINT in names
    print(f"\n{'contact point ' + CONTACT_POINT:52} {'PASS' if ok else 'FAIL':8} {names}")
    return 0 if ok else 1


if __name__ == "__main__":
    dash = json.loads(DASHBOARD.read_text())
    total = check_panels(dash) + check_rules() + check_contact_point()
    print(f"\n{'ALL PASSED' if total == 0 else f'{total} problem(s)'}")
    sys.exit(1 if total else 0)
