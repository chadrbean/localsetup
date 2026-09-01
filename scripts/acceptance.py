#!/usr/bin/env python3
"""End-to-end acceptance: one hard task via the auto-router vs forced kimi; prints cost delta.

Usage: LITELLM_MASTER_KEY=... LITELLM_GENERAL_KEY=... .venv/bin/python scripts/acceptance.py
"""
import json
import os
import time
import urllib.request

from openai import OpenAI

GATEWAY = "http://localhost:4000/v1"
ROUTER = "http://localhost:4000/v1"   # LiteLLM native auto router (RouteLLM retired)
ADMIN = "http://localhost:4000"   # admin endpoints (spend) live at the root, not /v1
MASTER = os.environ["LITELLM_MASTER_KEY"]
GENERAL = os.environ["LITELLM_GENERAL_KEY"]

PROMPT = (
    "Compare S-corp vs C-corp for a founder: payroll tax, QBI deduction, "
    "entity conversion, and exit scenarios. Note where US tax-law caveats "
    "apply. Max 150 words."
)


def spend_since(t0: str):
    req = urllib.request.Request(
        f"{ADMIN}/spend/logs?start_time={t0}",
        headers={"Authorization": f"Bearer {MASTER}"},
    )
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def main() -> int:
    t0 = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z"
    ga = OpenAI(base_url=GATEWAY, api_key=GENERAL)

    r = ga.chat.completions.create(
        model="auto", messages=[{"role": "user", "content": PROMPT}], max_tokens=300
    )
    print("auto router ->", r.model)
    k = ga.chat.completions.create(
        model="kimi", messages=[{"role": "user", "content": PROMPT}], max_tokens=300
    )
    print("forced kimi ->", k.model)

    time.sleep(2)
    costs: dict[str, float] = {}
    for row in spend_since(t0):
        key = row.get("model_group") or row.get("model") or "?"
        costs[key] = costs.get(key, 0) + (row.get("spend") or 0)
    print("spend for this run:", {m: round(c, 6) for m, c in costs.items()})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
