#!/usr/bin/env python3
"""
search_console_exporter.py — Google Search Console → Prometheus metrics.

Queries the Search Console searchanalytics API for the last 30 days of data
(page + country dimensions) and writes Prometheus text format to stdout or a
.prom file. Intended to be run by a systemd timer or cron, once per hour max
(GSC data has a 2–3 day lag so running more often wastes quota).

Usage:
    python3 search_console_exporter.py --output /var/lib/prometheus-textfiles/search_console.prom
    python3 search_console_exporter.py   # writes to stdout

Environment variables (override CLI args):
    GOOGLE_SA_KEY_PATH  — path to service account JSON key
    GSC_SITE_URL        — Search Console site identifier (e.g. sc-domain:otbla.com)

Metrics written:
    search_console_clicks_total{page,country}
    search_console_impressions_total{page,country}
    search_console_ctr{page}
    search_console_position_avg{page}
    search_console_scrape_success        (1=ok, 0=failed)
    search_console_scrape_timestamp_seconds
"""
import argparse
import datetime
import json
import os
import sys
import time

SCOPES = ["https://www.googleapis.com/auth/webmasters.readonly"]


def build_service(key_path: str):
    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    creds = service_account.Credentials.from_service_account_file(key_path, scopes=SCOPES)
    return build("searchconsole", "v1", credentials=creds, cache_discovery=False)


def fetch_rows(service, site_url: str, days: int = 30):
    end = datetime.date.today() - datetime.timedelta(days=3)   # GSC lag
    start = end - datetime.timedelta(days=days - 1)
    body = {
        "startDate": start.isoformat(),
        "endDate": end.isoformat(),
        "dimensions": ["page", "country"],
        "rowLimit": 1000,
        "startRow": 0,
    }
    rows = []
    while True:
        resp = service.searchanalytics().query(siteUrl=site_url, body=body).execute()
        batch = resp.get("rows", [])
        rows.extend(batch)
        if len(batch) < body["rowLimit"]:
            break
        body["startRow"] += body["rowLimit"]
    return rows


def escape_label(v: str) -> str:
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def rows_to_prometheus(rows: list) -> str:
    # Aggregate by page for ctr/position (these don't vary by country meaningfully)
    by_page: dict = {}
    lines = []

    lines.append("# HELP search_console_clicks_total Total clicks from Google Search (last 30d).")
    lines.append("# TYPE search_console_clicks_total gauge")
    lines.append("# HELP search_console_impressions_total Total impressions in Google Search (last 30d).")
    lines.append("# TYPE search_console_impressions_total gauge")

    for row in rows:
        page = row["keys"][0]
        country = row["keys"][1]
        clicks = row.get("clicks", 0)
        impressions = row.get("impressions", 0)
        ctr = row.get("ctr", 0.0)
        position = row.get("position", 0.0)

        lp = escape_label(page)
        lc = escape_label(country)
        lines.append(f'search_console_clicks_total{{page="{lp}",country="{lc}"}} {clicks}')
        lines.append(f'search_console_impressions_total{{page="{lp}",country="{lc}"}} {impressions}')

        if page not in by_page:
            by_page[page] = {"ctr": ctr, "position": position}

    lines.append("# HELP search_console_ctr Click-through rate by page (last 30d, cross-country avg).")
    lines.append("# TYPE search_console_ctr gauge")
    lines.append("# HELP search_console_position_avg Average search result position by page (last 30d).")
    lines.append("# TYPE search_console_position_avg gauge")
    for page, vals in by_page.items():
        lp = escape_label(page)
        lines.append(f'search_console_ctr{{page="{lp}"}} {vals["ctr"]:.6f}')
        lines.append(f'search_console_position_avg{{page="{lp}"}} {vals["position"]:.2f}')

    lines.append("# HELP search_console_scrape_success 1 if last scrape succeeded, 0 otherwise.")
    lines.append("# TYPE search_console_scrape_success gauge")
    lines.append("search_console_scrape_success 1")
    lines.append("# HELP search_console_scrape_timestamp_seconds Unix timestamp of last successful scrape.")
    lines.append("# TYPE search_console_scrape_timestamp_seconds gauge")
    lines.append(f"search_console_scrape_timestamp_seconds {time.time():.0f}")

    return "\n".join(lines) + "\n"


def failure_metrics() -> str:
    return (
        "# TYPE search_console_scrape_success gauge\n"
        "search_console_scrape_success 0\n"
        f"# TYPE search_console_scrape_timestamp_seconds gauge\n"
        f"search_console_scrape_timestamp_seconds {time.time():.0f}\n"
    )


def main():
    parser = argparse.ArgumentParser(description="Search Console → Prometheus exporter")
    parser.add_argument("--key-file", default=os.environ.get("GOOGLE_SA_KEY_PATH", ""),
                        help="Path to service account JSON key")
    parser.add_argument("--site", default=os.environ.get("GSC_SITE_URL", ""),
                        help="Search Console site URL (e.g. sc-domain:otbla.com)")
    parser.add_argument("--days", type=int, default=30,
                        help="Number of days to query (default: 30; GSC lags 2-3d)")
    parser.add_argument("--output", default="",
                        help="Write to this file instead of stdout (.prom extension expected)")
    args = parser.parse_args()

    if not args.key_file:
        print("ERROR: --key-file or GOOGLE_SA_KEY_PATH required", file=sys.stderr)
        sys.exit(1)
    if not args.site:
        print("ERROR: --site or GSC_SITE_URL required", file=sys.stderr)
        sys.exit(1)

    try:
        svc = build_service(args.key_file)
        rows = fetch_rows(svc, args.site, args.days)
        output = rows_to_prometheus(rows)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        output = failure_metrics()

    if args.output:
        tmp = args.output + ".tmp"
        with open(tmp, "w") as f:
            f.write(output)
        os.replace(tmp, args.output)
        print(f"Wrote {args.output} ({len(output)} bytes, {output.count(chr(10))} lines)")
    else:
        sys.stdout.write(output)


if __name__ == "__main__":
    main()
