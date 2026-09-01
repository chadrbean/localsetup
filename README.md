# llmlocalsetup

Local AI routing setup — a self-hosted, OpenAI-compatible gateway (LiteLLM + RouteLLM)
that routes every task to the cheapest model good enough for it.

## Goal

Most value per dollar:

- **DeepSeek V4-Flash** — implementation + automated repetitive tasks (the cost floor, ~$0.14/$0.28 per M, cache-hit $0.0028).
- **DeepSeek V4-Pro** — planning + medium coding + reasoning.
- **Kimi K2.6** — "reasonable high-end" escalator for hard coding / long docs / agentic work.

Plus automatic complexity routing (RouteLLM), per-consumer budgets (LiteLLM), and stacked
discounts: **off-peak scheduling**, **prompt caching**, and **batch APIs**.

## Stack

- **LiteLLM proxy** `:4000/v1` — explicit tier selection (`flash` / `pro` / `kimi`), budgets, fallbacks, spend logs, Redis cache.
- **RouteLLM** `:6060/v1` — automatic `flash` ↔ `pro` routing by calibrated threshold.
- **DeepSeek native** (to capture cache-hit + off-peak pricing); **OpenRouter** for the long tail (Kimi/Qwen/GLM/MiniMax).
- Docker + systemd, Redis, SQLite spend logs.

## Off-peak windows (re-verify monthly — DeepSeek changed these Aug 16, 2026)

- Peak = Mon–Fri **01:00–04:00 UTC** and **06:00–10:00 UTC** (7h/day).
- All other hours + weekends = **half price**.
- US Pacific: peak lands ~6–9pm and 11pm–3am, so the working day is naturally off-peak.

## Status

Planning complete — see [PLAN.md](PLAN.md). Execution pending (subagent-driven-development).
