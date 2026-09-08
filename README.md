# localsetup

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

- **LiteLLM proxy** `:4000/v1` — explicit tiers (`flash` / `pro` / `kimi`) + OpenRouter **lite** tier (`or-lite-glm` / `or-lite-qwen` — cheap, everyday) + OpenRouter **planning** tier (`or-plan-qwen` / `or-plan-minimax` — deep context, frontier reasoning) + `gpt5` / `kimi-code` + native **Auto Router v2** (model `auto`), budgets, fallbacks, spend logs, and guardrails (`hide-secrets`, prompt-injection heuristics). http://localhost:4000/ui
- **Provider principle: direct connection first, OpenRouter for the long tail.** Go direct whenever the economics justify it, and fall back to OpenRouter otherwise. Direct buys things an aggregator structurally cannot: DeepSeek native is the only way to get cache-hit ($0.0028/M) and off-peak pricing, and going direct sidesteps OpenRouter's account-level guardrail/data-policy layer — which is where *every* routing failure on 2026-09-07 originated (Z.AI flapping, free endpoints blocked). Use OpenRouter when a model isn't worth its own account, or when no direct option exists.
- Docker Compose (podman-compatible) + Postgres for keys/spend. Hermes wiring mirrored in `hermes/config.yaml` for reference (the live copy is `~/.hermes/config.yaml`).
- **Auto Router ladder (retuned 2026-09-07):** SIMPLE → `flash`, MEDIUM → `flash`, COMPLEX → `pro` ("most complex work"), REASONING → `or-plan-qwen` ("very complex" only). Driven by the LLM classifier on the **`agentic` rubric** — see [docs/USAGE.md §4](docs/USAGE.md) for why that one line matters and how to tell when the classifier is silently failing.
- **Note on OpenRouter workspace Guardrails** (openrouter.ai/workspaces/default/guardrails): Qwen and MiniMax needed explicit allow-listing (done 2026-09-05). **Z.AI intermittently returns `0 endpoints out of 17 ... Provider not allowed by guardrail` even while allowed** — observed on 2026-09-07 passing 3/3 and failing minutes later. That flap took out the router's classifier and silently degraded all routing to flash, so the classifier was moved to `or-lite-qwen`. A two-deployment classifier group does **not** fix this: OpenRouter returns 404 for a guardrail block and LiteLLM's `RetryPolicy` has no `NotFoundErrorRetries`, so it never fails over. Keep request-critical paths off flappy providers.

## Reference URLs

- Admin UI (log in with `LITELLM_MASTER_KEY`): http://localhost:4000/ui
- LiteLLM API — all model calls incl. `auto` router (Bearer key): http://localhost:4000/v1
- RouteLLM auto-router (RETIRED — replaced by LiteLLM native `auto`; was :6060)

## Off-peak windows (re-verify monthly — DeepSeek changed these Aug 16, 2026)

- Peak (2x) = Mon–Fri **01:00–04:00 UTC** and **06:00–10:00 UTC** (7h/day).
- Everything else + weekends = **half price**.
- Pacific: peak ≈ **6–9pm and 11pm–3am**; off-peak = **9–11pm and 3am–6pm** — the working day is naturally off-peak.

## Documentation

- **`./compose.sh <litellm|traefik> <args>`** — the supported way to run docker
  compose against these stacks (loads `.env`, pins the engine). Use it instead of
  bare `docker compose`/`podman-compose`; see `.env.example`.
- **[docs/USAGE.md](docs/USAGE.md)** — how to log in / pass credentials, use LiteLLM (tiers + `auto` router), set up from scratch, daily ops, troubleshooting.
- **[PLAN.md](PLAN.md)** — the implementation plan.
- **[docs/MODELS.md](docs/MODELS.md)** — model comparison + watchlist (date-stamped pricing).
- **[docs/OFF-PEAK.md](docs/OFF-PEAK.md)** — DeepSeek peak/off-peak windows, caching, batch.

## Edge proxy (traefik/)

`traefik/` runs the public TLS edge for `*.chadrbean.com` (Traefik v3,
Route53 DNS-01 wildcard cert, podman compose, sslh :8443 → :18443).
`caddy/` is the archived predecessor — kept, not running. See
[traefik/README.md](traefik/README.md).

## SSH brute-force protection (fail2ban/)

`fail2ban/` is a **native** (not containerized — rootless podman can't read
the journal or manage host firewall rules, see its README) fail2ban install
protecting sshd. Complements `traefik/`'s fail2ban HTTP middleware, which
can't see SSH traffic (sslh forwards it straight to sshd, bypassing
Traefik). See [fail2ban/README.md](fail2ban/README.md).

## Status

LIVE: LiteLLM gateway `:4000` in containers (tiers + native `auto` router), postgres on `:5433`,
budgets + spend logging working, Hermes wired through the gateway, off-peak cron guard in place.
Redis response cache: enabled (litellm `cache_params.type: redis`, container
`litellm_redis`, host `127.0.0.1:6380`, key namespace `litellm.response_cache`).
