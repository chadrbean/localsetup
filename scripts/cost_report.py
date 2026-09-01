#!/usr/bin/env python3
"""Cost report: spend by model / day / key, plus DeepSeek peak-window flag.

Usage: LITELLM_MASTER_KEY=... .venv/bin/python scripts/cost_report.py [--days N]
"""
import argparse
import json
import os
import sys
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone

BASE = os.environ.get("LITELLM_BASE", "http://localhost:4000")
KEY = os.environ["LITELLM_MASTER_KEY"]


def fetch(url: str):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {KEY}"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def is_peak(dt: datetime) -> bool:
    """DeepSeek peak: Mon-Fri 01:00-04:00 and 06:00-10:00 UTC (2x price)."""
    return dt.weekday() < 5 and ((1 <= dt.hour < 4) or (6 <= dt.hour < 10))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=30)
    args = ap.parse_args()
    since = (datetime.now(timezone.utc) - timedelta(days=args.days)).isoformat()
    logs = fetch(f"{BASE}/spend/logs?start_time={since}&limit=10000")

    by_model: dict[str, float] = defaultdict(float)
    by_day: dict[str, float] = defaultdict(float)
    by_key: dict[str, float] = defaultdict(float)
    peak_total = total = 0.0
    for r in logs:
        cost = r.get("spend") or 0
        model = r.get("model_group") or r.get("model") or "?"
        by_model[model] += cost
        day = (r.get("startTime") or "")[:10]
        if day:
            by_day[day] += cost
        by_key[r.get("api_key") or r.get("user_api_key") or "?"] += cost
        total += cost
        try:
            if is_peak(datetime.fromisoformat(r["startTime"].replace("Z", "+00:00"))):
                peak_total += cost
        except Exception:
            pass

    pct = 100 * peak_total / total if total else 0
    print(f"spend (last {args.days}d): ${total:.4f}  |  peak-window: ${peak_total:.4f} ({pct:.0f}%)")
    print("\nby model:")
    for m, c in sorted(by_model.items(), key=lambda x: -x[1]):
        print(f"  {m:28} ${c:.4f}")
    print("\nby day:")
    for d, c in sorted(by_day.items()):
        print(f"  {d}   ${c:.4f}")
    print("\nby key:")
    for k, c in sorted(by_key.items(), key=lambda x: -x[1]):
        print(f"  {k[:44]:46} ${c:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
