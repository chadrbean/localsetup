#!/usr/bin/env python3
"""Smoke-test every spine tier through the LiteLLM gateway.

Usage: LITELLM_MASTER_KEY=... .venv/bin/python scripts/smoke_test.py
"""
import os
import sys
from openai import OpenAI

BASE = os.environ.get("LITELLM_BASE", "http://localhost:4000/v1")
KEY = os.environ["LITELLM_MASTER_KEY"]
MODELS = os.environ.get("LITELLM_MODELS", "flash pro kimi").split()

c = OpenAI(base_url=BASE, api_key=KEY)
fails = 0
for m in MODELS:
    try:
        r = c.chat.completions.create(
            model=m,
            messages=[{"role": "user", "content": "Reply with the single word OK."}],
        )
        u = r.usage
        print(f"{m:8} -> {r.choices[0].message.content!r}  prompt={u.prompt_tokens} completion={u.completion_tokens}")
    except Exception as e:
        fails += 1
        print(f"{m:8} -> FAIL: {type(e).__name__}: {e}")
sys.exit(1 if fails else 0)
