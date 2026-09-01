# llmlocalsetup

Local AI routing setup — a self-hosted, OpenAI-compatible gateway (LiteLLM)
that routes every task to the cheapest model good enough for it.

## Goal

Most value per dollar:

- **DeepSeek V4-Flash** — implementation + automated repetitive tasks (the cost floor, ~$0.14/$0.28 per M, cache-hit $0.0028).
- **DeepSeek V4-Pro** — planning + medium coding + reasoning.
- **Kimi K2.6** — "reasonable high-end" escalator for hard coding / long docs / agentic work.

Plus automatic complexity routing (LiteLLM Auto Router v2, model `auto`), per-consumer budgets (LiteLLM), and stacked
discounts: **off-peak scheduling**, **prompt caching**, and **batch APIs**.

## Stack

- **LiteLLM proxy** `:4000/v1` — explicit tiers (`flash` / `pro` / `kimi`) + OpenRouter tier (`gpt5` / `minimax` / `glm-flash` / `kimi-code`) + native **Auto Router v2** (model `auto`), budgets, fallbacks, spend logs. http://localhost:4000/ui
- DeepSeek native (to capture cache-hit + off-peak pricing); **OpenRouter** for the long tail (Kimi/Qwen/GLM/MiniMax).
- Docker + systemd, Redis, SQLite spend logs.

## Reference URLs

- Admin UI (log in with `LITELLM_MASTER_KEY`): http://localhost:4000/ui
- LiteLLM API — all model calls incl. `auto` router (Bearer key): http://localhost:4000/v1
- RouteLLM auto-router (RETIRED — replaced by LiteLLM native `auto`; was :6060)

## Off-peak windows (re-verify monthly — DeepSeek changed these Aug 16, 2026)

- Peak (2x) = Mon–Fri **01:00–04:00 UTC** and **06:00–10:00 UTC** (7h/day).
- Everything else + weekends = **half price**.
- Pacific: peak ≈ **6–9pm and 11pm–3am**; off-peak = **9–11pm and 3am–6pm** — the working day is naturally off-peak.

## Documentation

- **[docs/USAGE.md](docs/USAGE.md)** — how to log in / pass credentials, use LiteLLM (tiers + `auto` router), set up from scratch, daily ops, troubleshooting.
- **[PLAN.md](PLAN.md)** — the implementation plan.
- **[docs/MODELS.md](docs/MODELS.md)** — model comparison + watchlist (date-stamped pricing).
- **[docs/OFF-PEAK.md](docs/OFF-PEAK.md)** — DeepSeek peak/off-peak windows, caching, batch.

## Status

LIVE: LiteLLM gateway `:4000` under systemd (tiers + native `auto` router), postgres on `:5433`,
budgets + spend logging working, Hermes wired through the gateway, off-peak cron guard in place.
