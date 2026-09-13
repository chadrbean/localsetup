#!/usr/bin/env python3
"""Verify that every panel query in a Grafana dashboard actually works.

For each panel target in the dashboard JSON it runs the query through Grafana's
/api/ds/query (same path the UI uses) and reports:

  PASS  query ran and returned data
  WARN  no data / unknown metric, but the panel description says "Empty is normal"
  FAIL  query error, unknown metric name, or no data where data is expected

It also checks that every litellm_* / promtail_custom_* / probe_* metric name a
panel references exists in Prometheus (catches renamed metrics), and with
--alerts reports any Grafana alert rule whose last evaluation errored.

Generate some traffic first (e.g. scripts/smoke_test.py) so traffic panels
have data. Stdlib only. Grafana admin creds come from the environment
(GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD) or monitoring/.env.

Usage:
  ./scripts/verify_dashboard.py                      # LiteLLM Gateway, last 24h
  ./scripts/verify_dashboard.py --from now-1h --alerts
  ./scripts/verify_dashboard.py --dashboard monitoring/dashboards/other.json

Exit code 0 when nothing FAILs, 1 otherwise.
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DASHBOARD = os.path.join(ROOT, "monitoring", "dashboards", "litellm-gateway.json")
EMPTY_OK_MARKER = "Empty is normal"
METRIC_RE = re.compile(r"\b((?:litellm|promtail_custom|probe)_[a-z0-9_]+)\b")


def load_env_file(path):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip("'\"")
    except FileNotFoundError:
        pass
    return env


class Grafana:
    def __init__(self, url, user, password):
        self.url = url.rstrip("/")
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {"Authorization": f"Basic {token}", "Content-Type": "application/json"}

    def request(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path, data=data, method=method, headers=self.headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                return exc.code, json.loads(raw or b"{}")
            except ValueError:
                return exc.code, {"message": raw.decode(errors="replace")[:200]}


def iter_panels(panels):
    for panel in panels:
        if panel.get("type") == "row":
            yield from iter_panels(panel.get("panels", []))
        else:
            yield panel


def substitute_variables(expr, names):
    # Longest names first so $key_alias is never clobbered by a shorter $key.
    for name in sorted(names, key=len, reverse=True):
        expr = expr.replace("${%s}" % name, ".*").replace("$" + name, ".*")
    return expr


def frame_rows(result):
    rows = 0
    for frame in result.get("frames", []):
        values = frame.get("data", {}).get("values", [])
        if values:
            rows += len(values[0])
    return rows


def prometheus_metric_names(grafana):
    status, body = grafana.request("GET", "/api/datasources/proxy/uid/prometheus/api/v1/label/__name__/values")
    if status != 200:
        print(f"warning: could not list Prometheus metric names (HTTP {status})", file=sys.stderr)
        return None
    return set(body.get("data", []))


def check_panels(grafana, dashboard, time_from):
    variables = [v["name"] for v in dashboard.get("templating", {}).get("list", [])]
    known_metrics = prometheus_metric_names(grafana)
    results = []
    for panel in iter_panels(dashboard.get("panels", [])):
        empty_ok = EMPTY_OK_MARKER in (panel.get("description") or "")
        for target in panel.get("targets", []):
            ds = target.get("datasource") or panel.get("datasource") or {}
            expr = substitute_variables(target.get("expr", ""), variables)
            query = {"refId": target["refId"], "datasource": ds, "expr": expr,
                     "legendFormat": target.get("legendFormat", ""),
                     "intervalMs": 15000, "maxDataPoints": 300}
            if ds.get("type") == "loki":
                query["queryType"] = target.get("queryType", "range")
            else:
                query["instant"] = bool(target.get("instant"))
                query["range"] = not query["instant"]

            problems = []
            if known_metrics is not None and ds.get("type") == "prometheus":
                missing = sorted({m for m in METRIC_RE.findall(expr) if m not in known_metrics})
                if missing:
                    problems.append("unknown metric " + ", ".join(missing))

            status, body = grafana.request("POST", "/api/ds/query",
                                           {"queries": [query], "from": time_from, "to": "now"})
            result = body.get("results", {}).get(target["refId"], {})
            error = result.get("error") or (body.get("message") if status >= 400 else None)
            rows = 0 if error else frame_rows(result)

            if error:
                verdict, detail = "FAIL", f"query error: {error}"[:160]
            elif problems or rows == 0:
                detail = "; ".join(problems) or "no data"
                verdict = "WARN" if empty_ok else "FAIL"
            else:
                verdict, detail = "PASS", f"{rows} rows"
            results.append((verdict, panel.get("title", "?"), target["refId"], detail))
    return results


def check_alert_rules(grafana):
    status, body = grafana.request("GET", "/api/prometheus/grafana/api/v1/rules")
    if status != 200:
        return [("FAIL", "alert rules API", "-", f"HTTP {status}")]
    results = []
    for group in body.get("data", {}).get("groups", []):
        for rule in group.get("rules", []):
            health = rule.get("health", "?")
            verdict = "FAIL" if health == "error" else "PASS"
            detail = f"health={health} state={rule.get('state')}"
            if rule.get("lastError"):
                detail += f" error={rule['lastError'][:100]}"
            results.append((verdict, f"[rule] {rule.get('name')}", "-", detail))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--dashboard", default=DEFAULT_DASHBOARD)
    parser.add_argument("--grafana", default=os.environ.get("GRAFANA_URL", "http://127.0.0.1:3000"))
    parser.add_argument("--from", dest="time_from", default="now-24h")
    parser.add_argument("--alerts", action="store_true", help="also check Grafana alert rule health")
    args = parser.parse_args()

    env = load_env_file(os.path.join(ROOT, "monitoring", ".env"))
    user = os.environ.get("GRAFANA_ADMIN_USER") or env.get("GRAFANA_ADMIN_USER", "admin")
    password = os.environ.get("GRAFANA_ADMIN_PASSWORD") or env.get("GRAFANA_ADMIN_PASSWORD")
    if not password:
        sys.exit("GRAFANA_ADMIN_PASSWORD not set (env or monitoring/.env)")

    grafana = Grafana(args.grafana, user, password)
    with open(args.dashboard) as f:
        dashboard = json.load(f)

    results = check_panels(grafana, dashboard, args.time_from)
    if args.alerts:
        results += check_alert_rules(grafana)

    width = max(len(r[1]) for r in results) if results else 10
    print(f"{'':4}  {'panel / rule':<{width}}  ref  detail")
    for verdict, title, ref, detail in results:
        print(f"{verdict:4}  {title:<{width}}  {ref:<3}  {detail}")
    counts = {v: sum(1 for r in results if r[0] == v) for v in ("PASS", "WARN", "FAIL")}
    print(f"\n{dashboard.get('title')}: {counts['PASS']} pass, {counts['WARN']} warn, {counts['FAIL']} fail")
    sys.exit(1 if counts["FAIL"] else 0)


if __name__ == "__main__":
    main()
