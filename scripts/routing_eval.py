#!/usr/bin/env python3
"""Routing eval battery: easy prompts should route to flash, hard to pro.

Now tests LiteLLM's native Auto Router v2 (model "auto" on the gateway).
Usage: LITELLM_MASTER_KEY=... .venv/bin/python scripts/routing_eval.py
Env:  ROUTER_BASE  (default http://localhost:4000/v1)
      ROUTER_MODEL (default auto)
"""
import os
import sys

from openai import OpenAI

ROUTER_BASE = os.environ.get("ROUTER_BASE", "http://localhost:4000/v1")
ROUTER_MODEL = os.environ.get("ROUTER_MODEL", "auto")
KEY = os.environ["LITELLM_MASTER_KEY"]

EASY = [
    "What is the capital of France?",
    "What is 2 + 2?",
    "Translate 'hello' to Spanish.",
    "What day comes after Tuesday?",
    "Is 7 a prime number?",
    "What color is a clear sky?",
    "Convert 12 inches to feet.",
    "Write a one-sentence summary of 'The quick brown fox jumps over the lazy dog'.",
]

HARD = [
    "Design a distributed rate limiter for a multi-tenant API. Compare token bucket vs sliding window under adversarial bursts, include edge cases, and analyze failure modes.",
    "A test passes locally but fails in CI ~30% of the time. List every plausible root cause (timing, shared state, environment, resource leaks), how to distinguish each, and the retry-vs-fix tradeoff.",
    "Write a complete spec for an event-sourced accounting ledger supporting multi-currency. Identify the three hardest consistency problems and how you would solve them.",
    "Compare S-corp vs C-corp for a founder: payroll tax, QBI deduction, entity conversion, and exit scenarios. Note where US tax-law caveats apply.",
    "An ambiguous product requirement has five stakeholder interpretations. Produce a decision matrix resolving the ambiguity and a phased implementation plan.",
]


def main() -> int:
    c = OpenAI(base_url=ROUTER_BASE, api_key=KEY)
    cases = [("easy", p) for p in EASY] + [("hard", p) for p in HARD]
    routed = {"flash": 0, "pro": 0, "other": 0, "error": 0}
    print(f"{'expect':6} {'routed-to':10} content")
    print("-" * 70)
    for expect, prompt in cases:
        try:
            r = c.chat.completions.create(
                model=ROUTER_MODEL,
                messages=[{"role": "user", "content": prompt}],
                max_tokens=40,
            )
            actual = (r.model or "?").split("/")[-1]
            bucket = "flash" if "flash" in actual else ("pro" if "pro" in actual else "other")
            routed[bucket] += 1
            content = (r.choices[0].message.content or "")[:45]
            print(f"{expect:6} {actual:10} {content!r}")
        except Exception as e:
            routed["error"] += 1
            print(f"{expect:6} ERROR       {type(e).__name__}: {str(e)[:60]}")
    print("-" * 70)
    print(f"routed: {routed}")
    # hard->flash is the failure mode to watch
    return 1 if routed["error"] else 0


if __name__ == "__main__":
    sys.exit(main())
