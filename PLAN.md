# Cost-Efficient AI Routing Workflow (LiteLLM + RouteLLM) — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Route every task to the cheapest model good enough for it — a 3-model DeepSeek-centered spine (Flash for implementation + repetitive automation, Pro for planning, Kimi K2.6 for hard escalation), with automatic complexity routing, per-consumer budgets, and stacked discounts (off-peak scheduling, prompt caching, batch) that maximize value-per-dollar.

**Architecture:** A single LiteLLM proxy is the gateway (providers, tiers, budgets, fallbacks, cost logs). A RouteLLM "auto" endpoint sits in front, routing each request between Flash (weak) and Pro (strong) by calibrated threshold. Consumers point their OpenAI client at LiteLLM `:4000/v1` (explicit tier) or RouteLLM `:6060/v1` (auto). DeepSeek is used natively (to get cache + off-peak pricing); everything else rides OpenRouter.

**Tech Stack:** LiteLLM (proxy + SDK), RouteLLM (lm-sys `mf` router), DeepSeek API (native), OpenRouter (long tail), Docker + systemd, Redis (prompt/response cache), SQLite spend logs.

---

## 0. Strategy: highest value per dollar

### 0.1 The three workload classes

Every task you described falls into one of three buckets, each matched to the cheapest model that clears the quality bar:

| Class | Volume | Latency-sensitive? | Model | Why |
|-------|--------|--------------------|-------|-----|
| **Planning / high-end reasoning** | low | yes (interactive) | **DeepSeek V4-Pro** (default) → **Kimi K2.6** / Qwen3.8 Max / GPT-5 for frontier | Quality matters more than cost here; volume is tiny so even the $2/M tier is cheap |
| **Implementation / coding** | medium | medium | **DeepSeek V4-Flash** (default) → Pro/Kimi on escalation | Flash is a serious coder at the cost floor; RouteLLM auto-escalates hard cases |
| **Automated repetitive** | high | no | **DeepSeek V4-Flash, off-peak + cached prompts + batch** | Stack all three discounts on the cheapest model |

The spine is **three models** — everything else is a watchlist swap-in:

- **`flash`** = DeepSeek V4-Flash — $0.14/$0.28, cache-hit $0.0028, 1M ctx. The backbone. Highest value-per-dollar for implementation and repetitive work by a wide margin.
- **`pro`** = DeepSeek V4-Pro — ~$0.42/$0.84. Planning + medium coding + reasoning. Your current planner.
- **`kimi`** = Kimi K2.6 (or K2.7 Code) — $0.95/$4, 2M ctx. Best coder-per-dollar in the open-weight 80% cluster (80.2% SWE-bench); the "reasonable high-end" escalator for hard coding, long docs, and agentic work.

### 0.2 Time-of-day & discount levers (the "off-peak" answer)

Three discounts stack, in order of impact:

1. **DeepSeek off-peak pricing (NEW — changed Aug 16, 2026).** Peak = **Mon-Fri 01:00-04:00 UTC and 06:00-10:00 UTC**; all other hours (17h/day + weekends) are **half the peak rate**. The old "16:30-00:30 UTC" window is retired. In US Pacific, peak lands ~6-9pm and 11pm-3am — meaning your **US working day is naturally off-peak**. Schedule bulk/repetitive jobs outside those two windows to halve the (already cheapest) bill.
2. **Prompt caching.** DeepSeek V4-Flash cache-hit input is $0.0028/M (~50x cheaper than cache-miss). Repetitive tasks with a stable system prompt (classification, extraction, form-fill, the wave-repo capture pipeline) get this automatically via LiteLLM's Redis cache + DeepSeek's server-side cache. This is the single biggest win for automation.
3. **Batch APIs (50% off).** OpenAI, Google/Gemini, Anthropic all offer async batch at half price with up-to-24h turnaround — ideal for offline jobs (bulk summarization, embeddings, nightly enrichment). DeepSeek's equivalent lever is off-peak + cache rather than a separate batch endpoint. Use batch for anything that can wait.

**Stacked example:** a repetitive extraction job run off-peak with a cached prompt on Flash costs on the order of **$0.003/M effective input** — a ~10-50x saving over naive peak-time uncached use.

> **Data note:** you've opted to allow foreign (China-routed) models for financial data, so there is no provider lock on the tax/accounting workload. If that ever changes, the gateway's per-key `models` allowlist (Task 6) makes a US-only key a one-liner.

### 0.3 Full comparison table (approx USD in/out per 1M tokens, Aug 31 2026 — verify at pricepertoken.com)

| Model | Provider | In / Out | Cached in | Context | Role |
|-------|----------|----------|-----------|---------|------|
| DeepSeek V4-Flash | DeepSeek | $0.14/$0.28 | $0.003 | 1M | **backbone** (off-peak halves this) |
| Qwen3.7 Flash | Alibaba | $0.03-0.10/$0.40 | — | 1M | ultra-cheap alt to Flash |
| Grok 4.1 Fast | xAI | $0.20/$0.50 | — | 2M | cheap long-ctx + vision |
| GLM-4.5 Air | Zhipu | $0.20/$1.10 | $0.03 | 128K | cheap everyday reasoning |
| MiniMax M2 | MiniMax | $0.26/$1.02 | — | 196K | long ctx + multimodal |
| **DeepSeek V4-Pro** | DeepSeek | ~$0.42/$0.84 | — | 256K | **planning default** |
| GPT-4.1 Mini | OpenAI | $0.40/$1.60 | — | 1M | US mid tier |
| Qwen3.5 397B | Alibaba | $0.60/$3.60 | — | 1M | multilingual coder |
| GLM-5.x | Zhipu | ~$0.84/$3.36 | — | 200K+ | agentic tool-use |
| **Kimi K2.6/K2.7 Code** | Moonshot | $0.95/$4.00 | $0.16 | 2M | **hard-coding escalator** |
| Grok 4.3 | xAI | $1.25/$2.50 | — | 256K | balanced US |
| GPT-5 | OpenAI | $1.25/$10 | — | 400K | US frontier planning |
| Gemini 3.1 Pro | Google | ~$2/$8 | — | 1M+ | frontier coding |
| Qwen3.8 Max | Alibaba | $2/$6 | — | 256K | flagship coder |
| Grok 4.6 | xAI | $2/$6 | $0.50 | 200K+ | top Grok |
| Kimi K3 | Moonshot | ~$2.80/$14 | $0.30 | 1M | Moonshot flagship |

Coding signal (SWE-bench Verified, vendor board July 2026): the open-weight cluster — DeepSeek V4-Pro-Max 80.6%, Gemini 3.1 Pro 80.6%, MiniMax M3 80.5%, Qwen3.7 Max 80.4%, Kimi K2.6 80.2% — is within 0.4 points, at 10-50x less than the closed frontier. Sources: benchlm.ai, pricepertoken.com, llmabacus.com, morphllm.com, fireworks.ai, api-docs.deepseek.com, geotoolbox.ai.

---

## 1. Architecture

```
                         ┌─────────────────────────────┐
  Consumers              │   LiteLLM Proxy  :4000/v1   │   Providers
                         │   (tiers, budgets, fallbacks│
  Hermes  ──explicit────▶│    Redis cache, spend logs) │──▶ deepseek (flash/pro) NATIVE
  IDE / scripts ─explicit│                             │──▶ openrouter (kimi/qwen/glm/...)
                         └──────────────▲──────────────┘
  Browser agents  ──auto─▶ RouteLLM :6060/v1            │
  "complexity routing"   │  mf router (flash vs pro)    │
                         └──────────────┘───────────────┘
```

- **LiteLLM `:4000/v1`** = explicit tier. Client picks `flash`, `pro`, `kimi`, …
- **RouteLLM `:6060/v1`** = auto (flash↔pro). Both resolve through LiteLLM, so all traffic is budget-tracked.
- **DeepSeek native** (not OpenRouter) is essential: cache-hit pricing and the off-peak discount only apply on DeepSeek's own endpoint.

---

## 2. Files to Create

```
~/git/llmlocalsetup/
├── README.md                     # architecture + tiers + date-stamped pricing + off-peak windows
├── docs/MODELS.md                # full table + watchlist
├── docs/OFF-PEAK.md              # peak/off-peak windows, batch API notes, scheduling rules
├── .env.example                  # keys + master key (git-ignored)
├── litellm/
│   ├── config.yaml
│   └── docker-compose.yml        # litellm + redis
├── routellm/
│   ├── config.yaml
│   └── run.sh
├── scripts/
│   ├── smoke_test.py
│   ├── cost_report.py
│   ├── routing_eval.py
│   └── batch_job.py              # async/batch worker for repetitive tasks (off-peak)
└── systemd/
    └── llmlocalsetup.service
```

---

## 3. Task-by-Task Plan

### Task 1 — Scaffold repo + confirm model IDs, prices, off-peak windows

**Objective:** Pin exact slugs, prices, and the current peak/off-peak schedule so nothing downstream guesses.

**Files:** Create `README.md`, `docs/MODELS.md`, `docs/OFF-PEAK.md`, `.env.example`, `.gitignore`

**Step 1:** `mkdir -p ~/git/llmlocalsetup/{litellm,routellm,scripts,systemd,docs} && cd ~/git/llmlocalsetup && git init`

**Step 2:** Verify live data (pricepertoken.com, benchlm.ai, api-docs.deepseek.com): exact API slugs for DeepSeek V4-Flash/V4-Pro, Kimi K2.6/K3, Qwen3.7/3.8, GLM-5.x, Grok 4.1/4.6, GPT-5; current $/M; and **re-confirm the DeepSeek peak hours** (they changed Aug 16, 2026 — re-read the pricing page, don't trust this doc).

**Step 3:** Write `docs/OFF-PEAK.md`:
```
DeepSeek peak hours (as of <date>): Mon-Fri 01:00-04:00 UTC and 06:00-10:00 UTC.
All other hours + weekends = off-peak (half price).
Local translation (Pacific): peak ≈ 6-9pm and 11pm-3am. Bulk jobs run outside these.
Batch APIs: OpenAI / Gemini / Anthropic = 50% off, ~24h turnaround.
```

**Step 4:** Write `.env.example`:
```
LITELLM_MASTER_KEY=sk-master-CHANGE_ME
DEEPSEEK_API_KEY=
OPENROUTER_API_KEY=      # kimi/qwen/glm/minimax
XAI_API_KEY=             # grok (optional)
OPENAI_API_KEY=          # gpt-5 (optional)
GOOGLE_API_KEY=          # gemini (optional)
```
Write `.gitignore` (`.env`, `litellm/*.db`, `*.log`).

**Step 5:** Commit: `git add -A && git commit -m "chore: scaffold llmlocalsetup repo"`

**Verify:** repo init'd; off-peak windows recorded with a date; `.env.example` matches the providers below.

---

### Task 2 — LiteLLM config: spine + watchlist, fallbacks, caching

**Objective:** Declare the 3-model spine (plus watchlist) so the proxy knows every tier and fail-over.

**Files:** Create `litellm/config.yaml`

**Step 1:** Write config (verify slugs in Task 1):
```yaml
model_list:
  - model_name: flash
    litellm_params:
      model: deepseek/deepseek-v4-flash
      api_key: os.environ/DEEPSEEK_API_KEY
      fallbacks: ["pro"]                 # fail UP one tier only
  - model_name: pro
    litellm_params:
      model: deepseek/deepseek-v4-pro
      api_key: os.environ/DEEPSEEK_API_KEY
  - model_name: kimi
    litellm_params:
      model: openrouter/moonshotai/kimi-k2.6
      api_key: os.environ/OPENROUTER_API_KEY
      # no fallback — premium tier never silently escalates
  # watchlist (commented until a real need appears):
  # - model_name: qwen-max
  #   litellm_params: {model: openrouter/qwen/qwen3.8-max, api_key: os.environ/OPENROUTER_API_KEY}
  # - model_name: glm
  #   litellm_params: {model: openrouter/z-ai/glm-5.2, api_key: os.environ/OPENROUTER_API_KEY}
  # - model_name: gpt5
  #   litellm_params: {model: openai/gpt-5, api_key: os.environ/OPENAI_API_KEY}

litellm_settings:
  drop_params: true
  cache: true
  cache_params:
    type: redis
    host: redis
    port: 6379
    namespace: "airouting"
  num_retries: 2
  request_timeout: 120

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  disable_spend_logs: false
```

**Step 2:** Write `litellm/docker-compose.yml`:
```yaml
services:
  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    ports: ["4000:4000"]
    volumes:
      - ./config.yaml:/app/config.yaml
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    env_file: ../.env
    depends_on: [redis]
  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
```

**Step 3:** Commit: `git add -A && git commit -m "feat: litellm config — deepseek spine + watchlist"`

**Verify:** `docker compose config -q` parses clean.

---

### Task 3 — Start the proxy and prove the spine works

**Objective:** Gateway running, all three spine models responding.

**Step 1:** `cp .env.example .env`, fill real keys, then:
```bash
cd ~/git/llmlocalsetup/litellm && docker compose up -d
```

**Step 2:** `curl -s http://localhost:4000/health/liveliness` → expect "I'm alive".

**Step 3:** Create `scripts/smoke_test.py`:
```python
from openai import OpenAI
import os
c = OpenAI(base_url="http://localhost:4000/v1", api_key=os.environ["LITELLM_MASTER_KEY"])
for m in ["flash", "pro", "kimi"]:
    r = c.chat.completions.create(model=m, messages=[{"role":"user","content":"Reply OK."}])
    print(m, "->", r.choices[0].message.content, "| cost:", r.usage)
```
Run `python scripts/smoke_test.py` → three `OK` lines with non-zero cost.

**Step 4:** Confirm spend logging: `curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://localhost:4000/spend/logs | head`

**Verify:** three OK responses; spend rows exist.

---

### Task 4 — Install + calibrate RouteLLM (flash ↔ pro)

**Objective:** Auto-routing between Flash and Pro, tuned to route ~35% of calls to Pro.

**Files:** Create `routellm/config.yaml`, `run.sh`

**Step 1:** `cd ~/git/llmlocalsetup && uv venv routellm/.venv && source routellm/.venv/bin/activate && uv pip install routellm`

**Step 2:** Write `routellm/config.yaml`:
```yaml
strong_model: pro
weak_model: flash
```

**Step 3:** Calibrate:
```bash
export OPENAI_API_KEY=$LITELLM_MASTER_KEY
export OPENAI_API_BASE=http://localhost:4000/v1
python -m routellm.calibrate_threshold \
  --task calibrate --routers mf --strong-model-pct 0.35 \
  --config routellm/config.yaml
```
Expected: a finite threshold; record it.

**Step 4:** Write `routellm/run.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
export OPENAI_API_KEY="${LITELLM_MASTER_KEY:?}"
export OPENAI_API_BASE="http://localhost:4000/v1"
exec python -m routellm.openai_server \
  --routers mf --config routellm/config.yaml \
  --strong-model pro --weak-model flash --port 6060
```
`chmod +x routellm/run.sh`

**Verify:** threshold printed; `python -m routellm.openai_server --help` shows `--port`.

---

### Task 5 — Start RouteLLM and prove auto-routing

**Objective:** Easy prompts → Flash, hard prompts → Pro.

**Step 1:** `cd ~/git/llmlocalsetup && ./routellm/run.sh` (background); verify `curl -s http://localhost:6060/health` or "startup complete".

**Step 2:** Create `scripts/routing_eval.py` — ~20 prompts, half trivial, half genuinely hard. Send each to `http://localhost:6060/v1` with `model="auto"`.

**Step 3:** Log the winning model per call (from response or LiteLLM spend logs).

**Step 4:** Assert trivial→flash, hard→pro. Tune `--strong-model-pct` until strong share ≈ 35%.

**Verify:** cost report (Task 8) shows the flash/pro split near target.

---

### Task 6 — Per-consumer keys + budget caps

**Objective:** Cap spend per consumer; no shared unlimited key.

**Step 1:** General key (default for coding/docs):
```bash
curl -s -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models": ["flash","pro","kimi"], "max_budget": 50.0, "budget_duration": "1mo", "key_alias": "general"}'
```

**Step 2:** Automation key (flash-only, for the repetitive off-peak jobs — can't accidentally hit the premium tier):
```bash
curl -s -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models": ["flash"], "max_budget": 10.0, "budget_duration": "1mo", "key_alias": "automation"}'
```

**Step 3:** Enforcement test: throwaway key `max_budget: 0.0001`, call `kimi`, expect 402/429 + `BudgetExceeded` in logs.

**Verify:** over-budget rejected; the `automation` key cannot reach `pro`/`kimi`.

---

### Task 7 — Off-peak automation + caching (the value-per-dollar engine)

**Objective:** Repetitive jobs run cheap: Flash + cached prompts + off-peak windows.

**Step 1:** Design a stable system prompt for each repetitive task (extraction schema, classification rubric). Keeping the prefix byte-identical is what unlocks DeepSeek's $0.0028/M cache-hit rate. Document in `docs/OFF-PEAK.md`.

**Step 2:** Create `scripts/batch_job.py` — a queue worker that:
- reads a list of inputs,
- reuses one cached system prompt,
- runs through the proxy with `model="flash"` and the `automation` key,
- optionally uses an OpenAI/Gemini batch endpoint (50% off) when a task can tolerate 24h.

**Step 3:** Schedule it off-peak. Using Hermes cron (or systemd timer), fire `batch_job.py` during the DeepSeek off-peak window (e.g. US daytime / weekend), NOT in the two peak windows. Example cron: `0 14 * * *` (2pm local, off-peak) rather than `0 20 * * *`.

**Step 4:** Verify cache is hitting: two identical runs of the same input should show the second at ~$0.003/M effective input in the spend log.

**Verify:** repeated job's second run is dramatically cheaper (cache hit) and runs outside peak windows.

---

### Task 8 — Fallback test

**Objective:** Failure escalation never silently reaches the premium tier.

**Step 1:** Set `DEEPSEEK_API_KEY` to garbage, restart litellm, call `flash` → expect fallback to `pro`, NOT `kimi`.

**Step 2:** Restore key, restart, re-run `smoke_test.py` → green.

**Verify:** fallback chain honored; `kimi` never auto-selected.

---

### Task 9 — Cost reporting

**Objective:** One-command spend view by model/day, and a flag for peak-window spend.

**Files:** Create `scripts/cost_report.py`

**Step 1:** Aggregate `http://localhost:4000/spend/logs` → `model → total $` and `daily $ by model`, plus a "peak-hours $" line (UTC 01-04, 06-10 Mon-Fri) so you can see how much could shift off-peak.

**Step 2:** Run `python scripts/cost_report.py`.

**Verify:** readable table; premium spend is a small fraction; peak-hour spend identified.

---

### Task 10 — Wire Hermes

**Objective:** Your agent traffic flows through the gateway, tiered and tracked.

**Step 1:** Custom provider (see hermes-agent skill `references/providers-and-models.md`):
```bash
hermes config set model.provider custom
hermes config set model.base_url "http://localhost:4000/v1"
hermes config set model.api_key "sk-..."     # the "general" key
hermes config set model.model deepseek-v4-pro
```

**Step 2:** Aliases for the plan/implement split:
```bash
hermes config set model.aliases.flash "custom/flash"   # implement
hermes config set model.aliases.pro   "custom/pro"     # plan
hermes config set model.aliases.kimi  "custom/kimi"    # hard escalation
```

**Step 3:** Test `/model flash` (trivial), `/model pro` (planning), `/model kimi` (hard) — each lands on the right model in spend logs.

**Caveat:** Hermes needs streaming + tool-calling; both transparent through LiteLLM. If regressions appear, keep Hermes on native `deepseek` and use the proxy for scripts/IDE/browser.

**Verify:** `/model` switches land on the expected underlying model.

---

### Task 11 — Wire remaining consumers (browser automation, IDE, scripts)

**Objective:** Everything else points at the gateway.

**Step 1:** Wave-repo / cdp browser automation: `base_url="http://localhost:4000/v1"`, `automation` key, default `flash`; `pro` for extraction/analysis; `grok-fast` if vision/long-ctx needed later.

**Step 2:** IDE (Cursor/Codex/aider): base URL + `general` key; explicit model names per task.

**Step 3:** Ad-hoc scripts reuse the 4-line `OpenAI(...)` pattern.

**Verify:** each consumer logs under its own key alias.

---

### Task 12 — Persistence (systemd) + docs + commit

**Objective:** Survive reboots; reproducible.

**Step 1:** `systemd/llmlocalsetup.service` running `docker compose up` (litellm+redis) and the RouteLLM `run.sh` as `Restart=always`.

**Step 2:** `sudo systemctl enable --now llmlocalsetup`; verify `systemctl status`.

**Step 3:** Write `README.md` (architecture, tiers, off-peak schedule, how-to) and finish `docs/MODELS.md`.

**Step 4:** Commit: `git add -A && git commit -m "feat: ai routing gateway — litellm + routellm + budgets + off-peak"`.

**Verify:** `systemctl status` active; fresh clone + `.env` reproduces the stack.

---

### Task 13 — End-to-end acceptance + cost-per-task

**Objective:** Prove cheaper + still correct on real work.

**Step 1:** One real task of each type (spec-driven dev, browser scrape, document manipulation, tax calc). Run each twice: forced to `kimi` (baseline), then through `auto`.

**Step 2:** Compare quality vs cost (spend-log delta).

**Step 3:** Measure cost-per-successful-task over a week (including off-peak savings) vs your current DeepSeek-direct spend.

**Verify:** ≥50% cheaper than an all-premium baseline, no task failing quality review.

---

## 4. Risks, Tradeoffs, Open Questions

**Risks**
- **Peak/off-peak schedule is new + volatile.** DeepSeek changed it Aug 16, 2026 (and retired the old V3/R1 window). Re-check api-docs.deepseek.com monthly; the windows in this plan can shift. A cron reminder to re-verify is worth it.
- **Price/ID churn.** Chinese vendors repackage fast (K2.5→K2.6→K3, Qwen3.5→3.8) and quote in CNY. Pin slugs+prices in `docs/MODELS.md`, re-verify monthly.
- **OpenRouter margin + no cache pass-through.** Kimi/Qwen/GLM via OpenRouter cost ~5-20% more and may not expose cache-hit pricing. DeepSeek is native specifically to capture cache + off-peak. If Kimi becomes load-bearing, switch it to Moonshot native.
- **RouteLLM is binary + dormant** (2024). It can't do N-way tiers — the explicit-tier LiteLLM path covers that. If `mf` underperforms, swap to `sw_ranking` or Meta's KModel Router.
- **Router misrouting hard→Flash** = silent quality loss. Mitigate with the eval battery + low threshold + per-request model logging.
- **Fallback silently escalating to premium.** Mitigated: `flash`→`pro` only; `kimi` has no fallback.
- **Tool-calling/streaming through RouteLLM** may not pass perfectly; Hermes stays on LiteLLM-direct if it breaks.

**Tradeoffs**
- Local proxy = one more thing to run, but it's the single choke point enabling budgets, cache, off-peak scheduling, and spend visibility.
- Redis adds a dependency but ~doubles DeepSeek savings (cache-hit ≈ 50x cheaper). Drop for v1 if you want zero moving parts.
- Two endpoints (explicit vs auto) = a small complexity cost, bought with an escape hatch when the router misroutes.

**Open questions**
1. Batch APIs: use OpenAI/Gemini batch (50% off, 24h) for any latency-tolerant bulk job, or keep everything on DeepSeek off-peak + cache? (Default: DeepSeek-only for v1; batch as a phase-2 add.)
2. Redis caching in v1, or start without it?
3. Repo at `~/git/llmlocalsetup`, or fold into an existing repo?

---

## 5. Execution Handoff

Plan complete and saved. Ready to execute using subagent-driven-development — fresh subagent per task (scaffold → litellm config → proxy up → routellm calibrate → auto-routing → keys/budgets → off-peak automation → fallback → cost report → hermes → consumers → systemd → acceptance) with two-stage review after each. Shall I proceed?
