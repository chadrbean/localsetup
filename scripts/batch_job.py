#!/usr/bin/env python3
"""Off-peak batch worker: repetitive tasks through flash with a stable (cached) system prompt.

Usage:
  LITELLM_AUTOMATION_KEY=... .venv/bin/python scripts/batch_job.py inputs.jsonl [out.jsonl]

Input format: JSONL, one record per line: {"id": "...", "prompt": "..."}
Output: out.jsonl with {"id": ..., "output"|"error": ...}

Design notes (see docs/OFF-PEAK.md):
  - ONE stable system prompt per job type -> DeepSeek server-side prompt cache
    (~$0.0028/M input vs $0.14/M cache-miss).
  - model=flash + the automation key (flash-only, $10/mo cap).
  - Schedule via cron/systemd timer during DeepSeek OFF-PEAK hours:
    NOT Mon-Fri 01:00-04:00 UTC or 06:00-10:00 UTC (those are 2x price).
    Example (US Pacific, weekday 2pm = off-peak):  0 14 * * 1-5
"""
import json
import os
import sys

from openai import OpenAI

BASE = os.environ.get("LITELLM_BASE", "http://localhost:4000/v1")
KEY = os.environ["LITELLM_AUTOMATION_KEY"]
MODEL = os.environ.get("BATCH_MODEL", "flash")

SYSTEM_PROMPT = os.environ.get(
    "BATCH_SYSTEM_PROMPT",
    "You are a precise extraction engine. Respond with ONLY a compact JSON object "
    "matching the requested schema. No explanations, no markdown.",
)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    inp = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else sys.argv[1] + ".out.jsonl"
    c = OpenAI(base_url=BASE, api_key=KEY)
    n_ok = n_err = 0
    with open(inp) as f, open(out, "w") as g:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            try:
                r = c.chat.completions.create(
                    model=MODEL,
                    messages=[
                        {"role": "system", "content": SYSTEM_PROMPT},
                        {"role": "user", "content": rec["prompt"]},
                    ],
                    temperature=0,
                    max_tokens=300,
                )
                g.write(json.dumps({"id": rec.get("id"), "output": r.choices[0].message.content}) + "\n")
                n_ok += 1
            except Exception as e:
                n_err += 1
                g.write(json.dumps({"id": rec.get("id"), "error": str(e)}) + "\n")
    print(f"done: ok={n_ok} err={n_err} -> {out}")


if __name__ == "__main__":
    sys.exit(main())
