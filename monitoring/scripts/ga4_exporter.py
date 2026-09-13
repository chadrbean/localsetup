#!/usr/bin/env python3
"""
ga4_exporter.py — Google Analytics 4 → Prometheus text-format metrics.

Queries the GA4 Data API for the last 30 days and writes Prometheus metrics
to stdout or a .prom file. Run via systemd timer (see ga4-exporter.service),
at most once per hour — GA4 data is only updated a few times daily.

Environment variables:
    GOOGLE_SA_KEY_PATH   — path to service account JSON key
    GA4_PROPERTY_ID      — e.g. properties/553934934

Metrics written:
    ga4_sessions_total{date}
    ga4_pageviews_total{date}
    ga4_active_users{date}
    ga4_new_users_total{date}
    ga4_sessions_by_source{source,medium}
    ga4_pageviews_by_page{page}
    ga4_scrape_success
    ga4_scrape_timestamp_seconds
"""
import argparse
import os
import sys
import time


def escape_label(v: str) -> str:
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def build_client(key_path: str):
    from google.oauth2 import service_account
    from google.analytics.data_v1beta import BetaAnalyticsDataClient
    creds = service_account.Credentials.from_service_account_file(
        key_path,
        scopes=["https://www.googleapis.com/auth/analytics.readonly"],
    )
    return BetaAnalyticsDataClient(credentials=creds)


def run_report(client, property_id: str, dimensions: list, metrics: list, days: int = 30):
    from google.analytics.data_v1beta.types import (
        DateRange, Dimension, Metric, RunReportRequest,
    )
    req = RunReportRequest(
        property=property_id,
        date_ranges=[DateRange(start_date=f"{days}daysAgo", end_date="yesterday")],
        dimensions=[Dimension(name=d) for d in dimensions],
        metrics=[Metric(name=m) for m in metrics],
        limit=1000,
    )
    return client.run_report(req)


def to_prometheus(lines: list, resp, metric_names: list, dim_names: list, helps: dict) -> None:
    for mn in metric_names:
        if mn in helps:
            lines.append(f"# HELP {mn} {helps[mn]}")
        lines.append(f"# TYPE {mn} gauge")
    for row in resp.rows:
        label_str = ",".join(
            f'{escape_label(dim_names[i])}="{escape_label(row.dimension_values[i].value)}"'
            for i in range(len(dim_names))
        )
        for j, mn in enumerate(metric_names):
            val = row.metric_values[j].value
            lines.append(f"{mn}{{{label_str}}} {val}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-file", default=os.environ.get("GOOGLE_SA_KEY_PATH", ""))
    parser.add_argument("--property", default=os.environ.get("GA4_PROPERTY_ID", ""))
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--output", default="")
    args = parser.parse_args()

    if not args.key_file:
        print("ERROR: --key-file or GOOGLE_SA_KEY_PATH required", file=sys.stderr)
        sys.exit(1)
    if not args.property:
        print("ERROR: --property or GA4_PROPERTY_ID required", file=sys.stderr)
        sys.exit(1)

    lines = []
    try:
        client = build_client(args.key_file)

        # Daily sessions / pageviews / users
        r1 = run_report(client, args.property,
                        dimensions=["date"],
                        metrics=["sessions", "screenPageViews", "activeUsers", "newUsers"],
                        days=args.days)
        to_prometheus(lines, r1,
            metric_names=["ga4_sessions_total", "ga4_pageviews_total", "ga4_active_users", "ga4_new_users_total"],
            dim_names=["date"],
            helps={
                "ga4_sessions_total": "GA4 sessions per day (last 30d).",
                "ga4_pageviews_total": "GA4 screen/page views per day (last 30d).",
                "ga4_active_users": "GA4 active users per day (last 30d).",
                "ga4_new_users_total": "GA4 new users per day (last 30d).",
            })

        # Sessions by source/medium
        r2 = run_report(client, args.property,
                        dimensions=["sessionSource", "sessionMedium"],
                        metrics=["sessions"],
                        days=args.days)
        to_prometheus(lines, r2,
            metric_names=["ga4_sessions_by_source"],
            dim_names=["source", "medium"],
            helps={"ga4_sessions_by_source": "GA4 sessions by traffic source/medium (last 30d)."})

        # Top pages by views
        r3 = run_report(client, args.property,
                        dimensions=["pagePath"],
                        metrics=["screenPageViews"],
                        days=args.days)
        to_prometheus(lines, r3,
            metric_names=["ga4_pageviews_by_page"],
            dim_names=["page"],
            helps={"ga4_pageviews_by_page": "GA4 pageviews by page path (last 30d)."})

        lines.append("# TYPE ga4_scrape_success gauge")
        lines.append("ga4_scrape_success 1")

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        lines = ["# TYPE ga4_scrape_success gauge", "ga4_scrape_success 0"]

    lines.append("# TYPE ga4_scrape_timestamp_seconds gauge")
    lines.append(f"ga4_scrape_timestamp_seconds {time.time():.0f}")

    output = "\n".join(lines) + "\n"

    if args.output:
        tmp = args.output + ".tmp"
        with open(tmp, "w") as f:
            f.write(output)
        os.replace(tmp, args.output)
        print(f"Wrote {args.output} ({len(output)} bytes)")
    else:
        sys.stdout.write(output)


if __name__ == "__main__":
    main()
