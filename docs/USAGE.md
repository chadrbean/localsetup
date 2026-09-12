# llmlocalsetup — Usage Guide

How to log in, pass credentials, and use the LiteLLM gateway (tiers + native `auto` router).
Written 2026-08-31 for the live setup on this machine.

---

## 1. What's running

| Service | Port | Purpose |
|---------|------|---------|
| LiteLLM gateway (podman `litellm_litellm_1`, in pod `pod_litellm`) | `http://localhost:4000` | All model traffic, explicit tiers, `auto` router, budgets, spend logs |
| LiteLLM gateway log volume (podman `litellm_logs`) | container `/var/log/litellm/proxy.log` | Persistent stdout append (not auto-rotated) — survives restarts (2026-09-09); journald is the rotation-managed store |
| Postgres (podman `litellm_db`) | `127.0.0.1:5433` | Virtual keys + spend history (persistent) |
| Redis (podman `litellm_redis`) | `127.0.0.1:6380` | LiteLLM response cache (persistent) |
| Prometheus (podman `monitoring_prometheus`, pod `pod_monitoring`) | `127.0.0.1:9090` | Scrapes LiteLLM `/metrics/` (master-key bearer) + itself |
| Grafana (podman `monitoring_grafana`) | `127.0.0.1:3000` (public: `https://grafana.chadrbean.com:8443` via traefik) | LiteLLM dashboards; **own login** (admin / `GRAFANA_ADMIN_PASSWORD` in `.env`) |
| KopiaUI (native desktop app, XDG autostart) | n/a (desktop app, S3 backend) | Backs up `/home/chad`, `~/.local/share/wave`, `/usr/local/bin` to S3 (`chadrbean-backups`). Config/policies tracked in `kopia/`, see `kopia/README.md`. |

The whole stack runs as one **compose project** — `litellm/docker-compose.yml`
(see its header). Manage it with the repo wrapper, which runs podman-compose
(this box's compose engine — no docker installed):

```bash
cd ~/git/localsetup
./compose.sh litellm config                 # validate the compose file
./compose.sh litellm up -d                  # create/start (pods the project)
podman ps                                   # status (compose ps is unreliable here)
```

### Monitoring (prometheus + grafana)

Same compose-project pattern, own directory (`monitoring/`):

```bash
./compose.sh monitoring up -d               # pod pod_monitoring (prom + grafana)
podman ps | grep monitoring                 # monitoring_prometheus / monitoring_grafana
```

- Grafana public URL: `https://grafana.chadrbean.com:8443` (traefik router
  `grafana`, **fail2ban middleware only** — auth is Grafana's own admin login;
  deliberately no basic-auth middleware on top).
- Credentials: `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` in `.env`
  (example + generate hint in `.env.example`).
- Prometheus is loopback-only (`127.0.0.1:9090`); it scrapes LiteLLM's
  `/metrics/` with the master key from `monitoring/prometheus/bearer_token`
  (git-ignored; regenerate with `./scripts/refresh_bearer_token.sh` after a
  master-key rotation or fresh clone).
- LiteLLM dashboards: `monitoring/data/dashboards/*.json` (git-ignored). Fetch
  the official one with `./scripts/fetch_litellm_dashboard.sh`, then
  `podman restart monitoring_grafana` (provisioning loads on start).
- Failed Grafana logins are banned by the native fail2ban `grafana` jail
  (see `fail2ban/README.md`).

---

## 2. Credentials — how you log in

There is **no interactive login**. Every endpoint is OpenAI-compatible:
you pass a key as `Authorization: Bearer <key>`. The key IS your identity.

All keys live in **`~/git/localsetup/.env`** (git-ignored — never commit it).
That file is the single source of truth. It is created by `cp .env.example .env`
then filling in real values.

| Variable | What it is | Used for |
|----------|-----------|----------|
| `LITELLM_MASTER_KEY` | Admin key | Creating keys, viewing spend, admin endpoints. Treat like a root password. |
| `LITELLM_GENERAL_KEY` | Normal-use key (flash/pro/kimi, $50/mo) | Interactive work: Hermes (provider `gateway`), IDE, ad-hoc scripts |
| `LITELLM_OPENROUTER_KEY` | OpenRouter-tier key (gpt5/minimax/glm-flash/kimi-code/kimi, $15/mo) | Hermes aliases gpt5/minimax/glm-flash/kimi-code (provider `gateway-or`) — guardrailed tier, cannot touch flash/pro |
| `LITELLM_AUTOMATION_KEY` | Flash-only key ($10/mo) | Cron/batch/automation — cannot touch pro or kimi |
| `DEEPSEEK_API_KEY` | Provider key (DeepSeek **direct** — this is what buys cache-hit + off-peak pricing) | Under the hood — the gateway uses it |
| `ZAI_API_KEY` | Provider key (Z.AI direct → `zai-free`) | Under the hood — the gateway uses it |
| `OPENROUTER_API_KEY` | Provider key (OpenRouter → Kimi, GPT-5, MiniMax, GLM) | Under the hood — the gateway uses it |
| `LITELLM_DATABASE_URL` | Postgres URL | Under the hood |
| `LITELLM_DB_PASSWORD` | Postgres password | Under the hood |

**Which key for what:**
- Scripts and automation that repeat → `LITELLM_AUTOMATION_KEY` (can't accidentally blow $ on kimi).
- Your own interactive sessions (Hermes `gateway` provider) → `LITELLM_GENERAL_KEY`.
- OpenRouter-tier models (Hermes `gateway-or` provider; aliases gpt5/minimax/glm-flash/kimi-code) → `LITELLM_OPENROUTER_KEY`.
- Only create/list/delete keys or admin actions → `LITELLM_MASTER_KEY`.

All Hermes traffic goes through LiteLLM: the `gateway` and `gateway-or` providers both use
`base_url = http://localhost:4000/v1` — they differ only in which LiteLLM virtual key they
present, which is what enforces per-tier model allowlists and budgets.

Provider keys (DeepSeek/OpenRouter/Z.AI) come from the providers' dashboards; they are the
only credentials you sign up for. Everything else is generated locally.

**How the gateway sees them:** `.env` is **bind-mounted** into the container at `/app/.env`
(see `litellm/docker-compose.yml`) and read by LiteLLM itself to resolve `os.environ/NAME`
references in the config — it is *not* injected as process environment. So `podman exec
litellm_litellm_1 printenv` shows nothing, and **adding a new provider key means adding one
line to `.env` plus a restart — no compose change.**

---

## 3. Using LiteLLM — explicit tiers (`:4000`)

Pick the model yourself. Three model names:

| Model name | Backend | Price (in/out per 1M) | Best for |
|-----------|---------|----------------------|----------|
| `flash` | DeepSeek V4-Flash | ~$0.14/$0.28 (cache-hit $0.003) | implementation, repetitive, extraction |
| `pro` | DeepSeek V4-Pro | ~$0.42/$0.84 | planning, reasoning, medium coding |
| `kimi` | Kimi K2.6 (OpenRouter) | ~$0.95/$4.00 | hard coding, long docs — use sparingly |
| `or-lite-glm` / `or-lite-qwen` | GLM-5.3-Flash / Qwen3.7-Flash (OpenRouter) | ~$0.07-0.10/$0.25-0.40 | cheap everyday work, OpenRouter diversity from DeepSeek |
| `or-plan-qwen` / `or-plan-minimax` | Qwen3.8-Max / MiniMax-M3 (OpenRouter) | $2/$6, $0.30/$1.20 | deep context (256K/196K). `or-plan-qwen` is the Auto Router's **REASONING** tier — "very complex" only; `or-plan-minimax` is a cheaper manual pick |
| `kimi-code` | Kimi K2.7-Code (OpenRouter) | $0.66/$3.40 | hard-coding escalator — manual only, left the auto ladder 2026-09-07 |
| `gpt5` | GPT-5 (OpenRouter) | $1.25/$10 | frontier planning — use sparingly, guarded $15/mo openrouter-tier budget |
| `zai-free` | GLM-4.7-Flash (**Z.AI direct**) | $0/$0 | **opt-in only, heavily rate limited** — see below |

> ### ⚠ The free tier — what's actually true (measured 2026-09-07)
> **Z.AI direct (`zai-free`, GLM-4.7-Flash, 200K ctx)** is genuinely $0/$0 with no
> train-on-input consent required — but it is **heavily rate limited: 2/10 calls succeeded at
> ~10 req/min** (`ZaiException - Rate limit reached for requests`). Fine for an occasional
> manual `/model free`; unusable for the classifier or any agentic loop. Lifting the limit
> needs a $20 / 3-month credit purchase that would go largely unused, since DeepSeek `flash`
> beats Z.AI's paid models on price, output cost and cache ($0.14/$0.28 + $0.0028/M cache vs
> $0.15/$0.50 + $0.03/M).
>
> **OpenRouter's free tier was tried and dropped.** Its individual `:free` models are blocked
> by this account's data policy (`0 endpoints out of 1 requested ... matching your guardrail
> restrictions and data policy`) because they sit behind account settings named "Enable free
> endpoints that **may train on inputs**" / "…**may publish prompts**." That protection is
> correct and worth keeping — this box handles real bank statements and tax data. The only
> reachable option, the `openrouter/free` meta-model, returned 429 on 3/3 attempts anyway.
>
> **Net:** free capacity is not reliable from either provider. Treat it as a curiosity, not a
> tier you can build on.

**Reaching it:** `/model free` in Hermes, or `"model":"zai-free"` with `LITELLM_OPENROUTER_KEY`.
It is deliberately **absent** from `LITELLM_GENERAL_KEY`, so Hermes' default `gateway` provider
cannot land on it and stall.

(Alibaba/Qwen and MiniMax both required explicit allow-listing in the OpenRouter workspace Guardrails at openrouter.ai/workspaces/default/guardrails — both are now allowed as of 2026-09-05.)

**curl:**
```bash
# load keys into your shell (from the repo dir)
cd ~/git/localsetup && set -a && source .env && set +a

curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_GENERAL_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"pro","messages":[{"role":"user","content":"Plan the week"}]}'
```

**Python (any OpenAI-compatible client):**
```python
from openai import OpenAI
import os

# either os.environ has the key, or read it from ~/git/llmlocalsetup/.env
c = OpenAI(base_url="http://localhost:4000/v1", api_key=os.environ["LITELLM_GENERAL_KEY"])
r = c.chat.completions.create(
    model="flash",
    messages=[{"role": "user", "content": "Extract the dates from this text: ..."}],
)
print(r.choices[0].message.content)
```

**Admin endpoints (master key):**
```bash
curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://localhost:4000/v1/models   # list models
curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://localhost:4000/spend/logs # raw spend
./scripts/cost_report.py                                                              # pretty spend report
./scripts/create_keys.sh                                                               # create/mint new keys
```

**Create a new key (e.g. for a new app):**
```bash
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"models":["flash","pro"],"max_budget":5.0,"budget_duration":"1mo","key_alias":"myapp"}'
```
`models` is an allowlist — the key can ONLY call those. `max_budget` hard-caps spend
(429 once exceeded).

---

## 4. Using the Auto Router — automatic tiering (model `auto`)

LiteLLM's native **Auto Router v2** (beta) replaces RouteLLM: complexity routing
inside the gateway, so tool-calling and streaming work (RouteLLM's server rejected
OpenAI tool schemas, which is why it was retired — the unit file stays in `systemd/`
if you ever want it back).

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_GENERAL_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"<your prompt>"}]}'
```

```python
c = OpenAI(base_url="http://localhost:4000/v1", api_key=os.environ["LITELLM_GENERAL_KEY"])
r = c.chat.completions.create(model="auto", messages=[...])
```

**How it decides** (config in `litellm/litellm-config.yaml` under `model_name: auto`):
- Tiers (retuned 2026-09-07): SIMPLE → flash, MEDIUM → flash, COMPLEX → pro
  ("most complex work"), REASONING → or-plan-qwen ("very complex" only — the sole
  auto path to the $2/$6 flagship). `kimi-code` is no longer in the ladder; it stays
  a manual Hermes alias.
- Keyword rules are deterministic overrides (word-boundary matching, applied to the
  newest human message only): true tax-advice terms (1099/1040/s-corp/depreciation…)
  → REASONING; browser/scrape/extraction → SIMPLE. The old
  design/debug/refactor/plan → COMPLEX rule was **removed** — those are everyday
  words here and it forced the top tier on ordinary conversation.
- Everything else: LLM classifier (`or-lite-qwen`) on the **`agentic` rubric**, which
  anchors routine installs, builds, multi-file edits and standard debugging at MEDIUM.
  Falls back to the local heuristic scorer if the classifier call fails.
- Responses report the routed model (`return_raw_model_name: true`).

> **Why the rubric line matters.** `classification_rubric` defaults to `LEGACY`, which
> LiteLLM's own source warns "puts non-trivial code, multi-step technical work at the top
> of the scale… so ordinary engineering reads as top-tier and the router pays for the most
> expensive model on it." We ran unset (⇒ LEGACY) until 2026-09-07 and qwen3.8-max climbed
> to **89% of daily spend**. Setting `agentic` is the fix.

> **The classifier fails silently.** If the classifier model errors or times out, LiteLLM
> falls back to the heuristic scorer, which rates short prompts SIMPLE — so the whole ladder
> collapses onto flash while still returning 200s. Nothing surfaces to the caller. Both
> failure modes have happened here: an OpenRouter workspace guardrail blocking the classifier
> model's provider, and the classifier overrunning the 3000ms default `timeout_ms` (raised to
> 10000). **Check with:** `command grep -c "classifier failed" /var/log/litellm/proxy.log`
> (host path via the `litellm_logs` volume — see §7) — anything above zero means routing is
> degraded.

> **`auto` has a fallback net (fixed 2026-09-09).** `router_settings.fallbacks` now includes
> `auto: ["flash", "pro"]`, so when the tier the router picked times out or errors on
> OpenRouter, the request falls back to DeepSeek native flash, then pro — instead of
> returning a hard 408/400. Individual tier fallbacks (`or-plan-minimax → or-lite-deepseek-flash`,
> `or-lite-* → flash`, etc.) still apply within the router's tier selection.

**Force a stronger model without editing config:** include the phrase `LITELLM ESCALATE`
in your message. `escalation_keywords` defaults to that, and it bumps the request one tier.

**In Hermes:** `auto` is the default model (`/model auto` to switch back to it
explicitly). Note the classifier is fuzzy — for important planning, `/model pro`
or `/model plan` (Qwen3.8-Max, deep context) are the deterministic choices.
Re-tune tiers/keywords by editing `litellm/litellm-config.yaml` and running
`./compose.sh litellm restart litellm`.

**Re-run the eval battery:** `scripts/routing_eval.py` (tests model `auto`) — note
this predates the docker-compose rewrite and referenced a local `.venv/bin/python`
that no longer exists; re-point it at the system/container Python before relying on it.

## 4.5 Guardrails

`litellm/litellm-config.yaml` enables two zero-external-dependency guardrails:
- **`hide-secrets`** (`pre_call`) — scans prompts for known secret patterns
  (AWS keys, private keys, Stripe/NPM tokens, etc.) and redacts them before
  the model ever sees them. It does **not** catch generic `sk-`-prefixed keys
  (OpenAI/LiteLLM/OpenRouter-style) — only vendor-specific patterns.
- **`detect_prompt_injection`** (heuristics only — `similarity_check` is off;
  it loads/downloads an embedding model on first call and hung the proxy for
  minutes in testing).

---

## 5. Setting it up from scratch (new machine / reinstall)

Prereqs: `uv`, `python3`, `podman` (or docker), and API keys for DeepSeek + OpenRouter.

```bash
# 1. get the repo + secrets
git clone git@github.com:chadrbean/localsetup.git && cd localsetup
cp .env.example .env          # then EDIT .env: DEEPSEEK_API_KEY, OPENROUTER_API_KEY
                              # (LITELLM_MASTER_KEY: generate with: openssl rand -hex 24)

# 2. start the stack (postgres + redis + gateway) — the venv/prisma steps
#    below are only for the helper scripts (smoke_test, cost_report, routing_eval)
uv venv .venv
uv pip install --python .venv/bin/python 'litellm[proxy]' prisma openai
PATH="$PWD/.venv/bin:$PATH" .venv/bin/prisma generate \
  --schema=.venv/lib/python3.12/site-packages/litellm/proxy/schema.prisma

# 3. bring up the compose stack (postgres on 5433, redis on 6380, gateway on 4000)
./compose.sh litellm up -d      # podman-native; never plain docker

# 3b. optional: monitoring (prometheus + grafana on 9090/3000)
cp .env.example .env            # already done above; add GRAFANA_ADMIN_PASSWORD (openssl rand -hex 24)
./scripts/refresh_bearer_token.sh   # writes monitoring/prometheus/bearer_token from LITELLM_MASTER_KEY
./scripts/fetch_litellm_dashboard.sh  # official LiteLLM dashboard into monitoring/data/dashboards
./compose.sh monitoring up -d   # pod pod_monitoring; then podman restart monitoring_grafana

# 3c. optional: Kopia desktop backups (S3) + autostart — see kopia/README.md
#     for the full repository-connect / policy-import / autostart-install sequence

# 4. verify
sleep 25 && curl -s http://localhost:4000/health/liveliness
set -a; source .env; set +a
.venv/bin/python scripts/smoke_test.py      # flash/pro/kimi each reply OK
./scripts/create_keys.sh                     # mints general + automation + openrouter keys into .env
```

(The stack is compose-managed via `./compose.sh` — no systemd unit, no
`start_gateway.sh`/`install_systemd.sh` scripts.)

---

## 6. Daily operations

```bash
.venv/bin/python scripts/smoke_test.py      # health check all tiers
.venv/bin/python scripts/cost_report.py     # spend by model/day/key + peak-hour flag
.venv/bin/python scripts/routing_eval.py    # does the auto router still route correctly?
.venv/bin/python scripts/batch_job.py jobs.jsonl    # off-peak batch worker (flash only)

# recurring automation: schedule OFF-PEAK (avoid DeepSeek peak windows)
#   Peak (2x)  = Mon-Fri 6-9pm PT and 11pm-3am PT
#   Off-peak   = Mon-Fri 9-11pm PT and 3am-6pm PT + all weekend (half price)
#   Guard every job with run_offpeak.sh so it can never fire during peak:
#   30 14 * * 1-5  /home/chad/localsetup/scripts/run_offpeak.sh \
#                  && /home/chad/localsetup/.venv/bin/python \
#                     /home/chad/localsetup/scripts/batch_job.py jobs.jsonl
```

---

## 7. Troubleshooting

- **`key not allowed to access model` (403)** — you're using the wrong key for that
  model (e.g. automation key + kimi). Use `LITELLM_GENERAL_KEY` or mint a key that
  includes the model.
- **`Budget has been exceeded` (429)** — that key hit its monthly cap. Raise it via
  `/key/update` with the master key, or wait for reset.
- **Gateway won't start / `Unable to find Prisma binaries`** — re-run step 2's
  `prisma generate` (PATH must include `.venv/bin`).
- **`Port already in use`** — something else owns 4000/5433/6380; check
  `./compose.sh litellm ps` and `ss -tlnp`.
- **DeepSeek calls fail but kimi works** — `DEEPSEEK_API_KEY` wrong/expired in `.env`;
  gateway reloads keys on restart (`./compose.sh litellm restart litellm`).
- **Postgres down** — `./compose.sh litellm start db`; data is in the
  `litellm_postgres_data` volume (redis cache data in `litellm_redis_data`).
- **Router slow first request** — BERT checkpoint downloads from HuggingFace on first
  start (cached afterward). Set `HF_TOKEN` in `.env` to avoid rate-limit warnings.
- **Everything healthy but a model returns garbage** — check
  `scripts/routing_eval.py` output; if hard prompts route to flash, lower the router
  threshold in the model name (see section 4).
- **A request failed — where's the detail?** Failures land in **two** places:
  - **Per-request in Postgres (no config needed):** every failed row in `LiteLLM_SpendLogs`
    has `status='failure'` and its `metadata.error_information` already carries the full
    root cause — `error_code`, `error_class`, `error_message`, and a `traceback`. Example
    from the 2026-09-09 MiniMax outage:
    `error_class=Timeout, error_code=408, error_message="…Connection timed out. Timeout passed=45.0… No fallback model group found for original model_group=auto"`.
  - **Gateway stdout:** persisted on a named volume since 2026-09-09. Host path is
    `~/.local/share/containers/storage/volumes/litellm_logs/_data/proxy.log`
    (or `podman volume mount litellm_logs`). This is an append-via-`tee` file, not
    auto-rotated — truncate it if it grows (`: > .../proxy.log` is safe while the
    container runs; it reopens with `tee -a`). Pre-restart stdout is also
    in journald: `journalctl CONTAINER_NAME=litellm_litellm_1`.

---

## 8. Where the money goes (cost controls recap)

- Explicit tiers: you pick flash/pro/kimi.
- Auto: BERT router sends ~65% to flash, ~35% to pro.
- Budgets: every key has a hard monthly cap (429 when hit).
- Automation key: flash-only, so cron/batch can't touch premium models.
- Off-peak: DeepSeek halves the (already cheapest) price outside peak windows.
- Caching (two layers): **provider-side** prompt caching keeps system prompts
  byte-identical → DeepSeek cache-hit $0.0028/M (~50x cheaper); **proxy-side**
  Redis response cache (`litellm_redis`, host `127.0.0.1:6380`) returns the
  stored completion for identical repeated requests — no upstream call at all
  (key namespace `litellm.response_cache`, TTL 24h).

---

## 9. Vast.ai GPU rentals (adding/removing a rental model)

Rented vast.ai boxes (Ollama or vLLM) are wired in as plain zero-cost model entries
(`model_info` costs = 0 — the cost is the hourly rental). Full walkthrough with every
pitfall (probing the box, the 64K Hermes context floor, SSH tunnels, virtual-key
allowlists, cleanup): **see [`docs/VASTAI.md`](VASTAI.md)**.

Short version:
1. Probe the box → get the exact model id + true context window (vLLM `/v1/models`
   `max_model_len`, or `ollama show`).
2. Add a `model_list` entry (provider prefix `ollama_chat/` or `openai/` with the
   exact server id; vLLM needs an SSH tunnel to `127.0.0.1:18000`).
3. Restart the gateway; add the alias to the `LITELLM_GENERAL_KEY` allowlist.
4. In `~/.hermes/config.yaml`: set `model_overrides.gateway.<alias>.context_window`
   to the true value, add the alias to `providers.gateway.models`, refresh
   `provider_models_cache.json`.
5. Remember: **<64K context ⇒ cannot be the main Hermes agent model** (agent init
   rejects it); 32K 9B-class boxes are subagent/one-off only.
