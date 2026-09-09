# Model Comparison & Watchlist

Date-stamped: **Aug 31, 2026**. Prices are approximate USD per 1M tokens (input/output) and
**move frequently** — re-verify at pricepertoken.com / benchlm.ai before relying on them.
Chinese vendors quote in CNY (¥1 ≈ $0.14); conversions are rough.

## The spine (wired in LiteLLM)

| Alias | Model | Provider | In / Out | Cached in | Context | Role |
|-------|-------|----------|----------|-----------|---------|------|
| `flash` | DeepSeek V4-Flash | DeepSeek (native) | $0.14 / $0.28 | $0.0028 | 1M | default: implementation, repetitive automation, extraction, glue |
| `pro` | DeepSeek V4-Pro | DeepSeek (native) | ~$0.42 / ~$0.84 | — | 256K | planning, medium coding, reasoning |
| `kimi` | Kimi K2.6 | OpenRouter (moonshotai) | $0.95 / $4.00 | $0.16 | 2M | hard coding, long docs, agentic escalator |

## OpenRouter tier (guardrailed key LITELLM_OPENROUTER_KEY, $15/mo)

| Alias | Model | Provider | In / Out | Context | Role |
|-------|-------|----------|----------|---------|------|
| `kimi-code` | Kimi K2.7 Code | OpenRouter (moonshotai) | $0.66 / $3.40 | 262K | cheaper code-specialized escalator |
| `gpt5` | GPT-5 | OpenRouter (openai) | $1.25 / $10 | 400K | US-frontier planning + tool-calling (no OpenAI account needed) |
| `minimax` | MiniMax M3 | OpenRouter (minimax) | $0.30 / $1.20 | 1M | long-context + multimodal value king (80.5% SWE-bench) |
| `glm-flash` | GLM-5.3 Flash | OpenRouter (z-ai) | $0.07 / $0.25 | 1.3M | ultra-cheap huge-context: whole docs, bulk jobs |

The OpenRouter tier exists because DeepSeek native can't serve these models and no extra
accounts are needed — one OpenRouter key covers all of them. Slugs verified live on
openrouter.ai 2026-08-31. The real OpenRouter API key stays in the gateway .env; the
LiteLLM virtual key only scopes which tier Hermes/scripts may touch.

DeepSeek native is deliberate: cache-hit pricing ($0.0028/M) and the off-peak discount only
apply on DeepSeek's own endpoint, not through OpenRouter.

## Full comparison (research snapshot)

| Model | Provider | In / Out | Context | Notes |
|-------|----------|----------|---------|-------|
| DeepSeek V4-Flash | DeepSeek | $0.14/$0.28 | 1M | cost floor; serious coder |
| Qwen3.7 Flash | Alibaba | $0.03-0.10/$0.40 | 1M | ultra-cheap alt |
| Grok 4.1 Fast | xAI | $0.20/$0.50 | 2M | cheap long-ctx + vision |
| GLM-4.5 Air | Zhipu/Z.ai | $0.20/$1.10 | 128K | cheap everyday reasoning |
| MiniMax M2 | MiniMax | $0.26/$1.02 | 196K | long ctx + multimodal |
| DeepSeek V4-Pro | DeepSeek | ~$0.42/~$0.84 | 256K | planning default |
| GPT-4.1 Mini | OpenAI | $0.40/$1.60 | 1M | US mid tier |
| Qwen3.5 397B | Alibaba | $0.60/$3.60 | 1M | multilingual coder |
| GLM-5.x | Zhipu/Z.ai | ~$0.84/~$3.36 | 200K+ | agentic tool-use |
| Kimi K2.6 / K2.7 Code | Moonshot | $0.95/$4.00 | 2M | hard-coding escalator |
| Grok 4.3 | xAI | $1.25/$2.50 | 256K | balanced US |
| GPT-5 | OpenAI | $1.25/$10 | 400K | US frontier planning |
| Gemini 3.1 Pro | Google | ~$2/$8 | 1M+ | frontier coding |
| Qwen3.8 Max | Alibaba | $2/$6 | 256K | flagship coder |
| Grok 4.6 | xAI | $2/$6 | 200K+ | top Grok |
| Kimi K3 | Moonshot | ~$2.80/$14 | 1M | Moonshot flagship |

Also seen but skipped for v1: ERNIE 5.1 (Baidu), Hunyuan (Tencent), Doubao (ByteDance),
StepFun, Yi (01.AI) — thin Western tooling; add via OpenRouter if a need appears.

## Coding signal

SWE-bench Verified (vendor board, July 2026): open-weight cluster within 0.4 points —
DeepSeek V4-Pro-Max 80.6%, Gemini 3.1 Pro 80.6%, MiniMax M3 80.5%, Qwen3.7 Max 80.4%,
Kimi K2.6 80.2% — at 10-50x less than the closed frontier.

## Auto Router tier assignments (2026-09-08 retune, Qwen-forward)

| Tier | Model | Price | Rationale |
|------|-------|-------|-----------|
| SIMPLE | `or-lite-glm` (GLM-5.3-Flash) | $0.075/$0.25 | lookups, trivial asks |
| MEDIUM | `or-lite-qwen` (Qwen3.7-Flash) | $0.03/$0.13 | workhorse: routine engineering, installs, builds, multi-file edits, standard debugging |
| COMPLEX | `or-plan-minimax` (MiniMax M3) | $0.30/$1.20 | hard multi-step work; vendor-diverse from Alibaba |
| REASONING | `or-plan-qwen` (Qwen3.8-Max-0902) | $2/$6 | "very complex" only — commit-to-a-decision / genuine optimization |

Classifier: `or-lite-qwen` on the `agentic` rubric, `timeout_ms: 10000`.
`session_affinity: true` since 2026-09-08 — one classifier call per session instead of per turn.
Every *tier* fails down to the DeepSeek native spine (`or-lite-*` → `flash`, `or-plan-*` →
`pro`) via `router_settings.fallbacks`, **but the `auto` model group itself is not in the
fallback map (2026-09-09)** — when the router-selected tier times out on OpenRouter
(observed: MiniMax M3 / Qwen "Connection timed out"), `auto` returns hard **408** instead of
failing down. See docs/USAGE.md §4.
`kimi-code` is manual-only; DeepSeek `flash` remains Hermes' default.

**History:** the 2026-09-05..07 config (MEDIUM → `pro`, COMPLEX → `or-plan-qwen`, legacy
rubric) pushed qwen3.8-max to **89% of daily spend**. The 09-07 agentic-rubric retune anchored
routine engineering at MEDIUM→`flash`; the 09-08 retune moved the whole ladder to the Qwen
stack (user decision) with DeepSeek kept as the fallback net.

**Slug churn note (2026-09-08):** OpenRouter renamed `qwen/qwen3.8-max` → `qwen/qwen3.8-max-0902`;
the old slug 404'd on every call. Prices/context also refreshed: qwen3.7-flash $0.03/$0.13,
minimax-m3 and glm-5.3-flash both expose ~1M ctx.

## opencode integration (2026-09-08)

`~/.config/opencode/opencode.json` maps opencode agents onto the LiteLLM aliases:

| opencode use | Model |
|--------------|-------|
| default chat / build agent | `litellm/auto` (complexity router) |
| plan agent | `litellm/or-plan-minimax` (MiniMax M3 — verified against `~/.config/opencode/opencode.json` 2026-09-09; docs previously said or-plan-qwen) |
| `small_model` (titles/summaries) | `litellm/or-lite-qwen` |

Notes for reading LiteLLM usage: every `auto` request logs an `or-lite-qwen` *classifier* entry
on the dashboard in addition to the routed deployment row, and the `auto` parent row sums its
children — expect apparent double counting. Read per-deployment rows (`flash`, `or-lite-qwen`,
`or-plan-minimax`, …) for real spend.

## Watchlist rules

- Add a model to LiteLLM only when a real task needs it (YAGNI).
- Commented watchlist entries already exist in `litellm/config.yaml`.
- Re-verify slugs + prices monthly; DeepSeek peak/off-peak changed Aug 16, 2026.

Sources: benchlm.ai, pricepertoken.com, llmabacus.com, morphllm.com, fireworks.ai,
api-docs.deepseek.com, geotoolbox.ai.
