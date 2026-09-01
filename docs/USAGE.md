# llmlocalsetup — Usage Guide

How to log in, pass credentials, and use the LiteLLM gateway + RouteLLM auto-router.
Written 2026-08-31 for the live setup on this machine.

---

## 1. What's running

| Service | Port | Purpose |
|---------|------|---------|
| LiteLLM gateway | `http://localhost:4000` | All model traffic, explicit tiers, budgets, spend logs |
| RouteLLM auto-router | `http://localhost:6060` | Complexity routing: easy → flash, hard → pro |
| Postgres (podman `litellm-db`) | `127.0.0.1:5433` | Virtual keys + spend history (persistent) |

Managed by user-level systemd (start at boot, auto-restart):
```bash
systemctl --user status llmlocalsetup-gateway llmlocalsetup-router
journalctl --user -u llmlocalsetup-gateway -f     # live gateway logs
journalctl --user -u llmlocalsetup-router -f      # live router logs
```

---

## 2. Credentials — how you log in

There is **no interactive login**. Every endpoint is OpenAI-compatible:
you pass a key as `Authorization: Bearer <key>`. The key IS your identity.

All keys live in **`~/git/llmlocalsetup/.env`** (git-ignored — never commit it).
That file is the single source of truth. It is created by `cp .env.example .env`
then filling in real values.

| Variable | What it is | Used for |
|----------|-----------|----------|
| `LITELLM_MASTER_KEY` | Admin key | Creating keys, viewing spend, admin endpoints. Treat like a root password. |
| `LITELLM_GENERAL_KEY` | Normal-use key (flash/pro/kimi, $50/mo) | Interactive work: Hermes (provider `gateway`), IDE, ad-hoc scripts |
| `LITELLM_OPENROUTER_KEY` | OpenRouter-tier key (gpt5/minimax/glm-flash/kimi-code/kimi, $15/mo) | Hermes aliases gpt5/minimax/glm-flash/kimi-code (provider `gateway-or`) — guardrailed tier, cannot touch flash/pro |
| `LITELLM_AUTOMATION_KEY` | Flash-only key ($10/mo) | Cron/batch/automation — cannot touch pro or kimi |
| `DEEPSEEK_API_KEY` | Provider key (DeepSeek) | Under the hood — the gateway uses it |
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

Provider keys (DeepSeek/OpenRouter) come from the providers' dashboards; they are the
only credentials you sign up for. Everything else is generated locally.

---

## 3. Using LiteLLM — explicit tiers (`:4000`)

Pick the model yourself. Three model names:

| Model name | Backend | Price (in/out per 1M) | Best for |
|-----------|---------|----------------------|----------|
| `flash` | DeepSeek V4-Flash | ~$0.14/$0.28 (cache-hit $0.003) | implementation, repetitive, extraction |
| `pro` | DeepSeek V4-Pro | ~$0.42/$0.84 | planning, reasoning, medium coding |
| `kimi` | Kimi K2.6 (OpenRouter) | ~$0.95/$4.00 | hard coding, long docs — use sparingly |

**curl:**
```bash
# load keys into your shell (from the repo dir)
cd ~/git/llmlocalsetup && set -a && source .env && set +a

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

**How it decides** (config in `litellm/config.yaml` under `model_name: auto`):
- Tiers: SIMPLE → flash, MEDIUM → pro, COMPLEX → pro, REASONING → kimi-code.
- Keyword rules are deterministic overrides (word-boundary matching):
  tax/accounting words → REASONING; design/architecture/debug → COMPLEX;
  browser/scrape/extraction → SIMPLE.
- Everything else: LLM classifier (flash, 'agentic' rubric), falling back to the
  local heuristic scorer if the classifier call fails.
- Responses report the routed model (`return_raw_model_name: true`).

**In Hermes:** `/model auto` uses it. Note the classifier is fuzzy — for important
planning, `/model pro` is the deterministic choice. Re-tune tiers/keywords by
editing the config and restarting the gateway.

**Re-run the eval battery:** `routellm/.venv` is no longer needed;
`.venv/bin/python scripts/routing_eval.py` tests model `auto`.

---

## 5. Setting it up from scratch (new machine / reinstall)

Prereqs: `uv`, `python3`, `podman` (or docker), and API keys for DeepSeek + OpenRouter.

```bash
# 1. get the repo + secrets
git clone git@github.com:chadrbean/llmlocalsetup.git && cd llmlocalsetup
cp .env.example .env          # then EDIT .env: DEEPSEEK_API_KEY, OPENROUTER_API_KEY
                              # (LITELLM_MASTER_KEY: generate with: openssl rand -hex 24)

# 2. gateway venv + prisma (prisma powers virtual keys + spend DB)
uv venv .venv
uv pip install --python .venv/bin/python 'litellm[proxy]' prisma openai
PATH="$PWD/.venv/bin:$PATH" .venv/bin/prisma generate \
  --schema=.venv/lib/python3.12/site-packages/litellm/proxy/schema.prisma

# 3. postgres for keys/spend (localhost only, port 5433 — 5432 may be taken)
PW=$(openssl rand -hex 16)
printf 'LITELLM_DB_PASSWORD=%s\nLITELLM_DATABASE_URL=postgresql://litellm:%s@127.0.0.1:5433/litellm\n' "$PW" "$PW" >> .env
podman run -d --name litellm-db --restart=always \
  -e POSTGRES_USER=litellm -e POSTGRES_PASSWORD="$PW" -e POSTGRES_DB=litellm \
  -p 127.0.0.1:5433:5432 -v litellm-pgdata:/var/lib/postgresql/data \
  docker.io/library/postgres:16-alpine

# 4. router venv
uv venv routellm/.venv
uv pip install --python routellm/.venv/bin/python routellm pandarallel fastapi uvicorn shortuuid

# 5. start + verify
./scripts/start_gateway.sh &   # or: systemctl --user start llmlocalsetup-gateway
sleep 25 && curl -s http://localhost:4000/health/liveliness
./scripts/start_router.sh &    # or: systemctl --user start llmlocalsetup-router
set -a; source .env; set +a
.venv/bin/python scripts/smoke_test.py      # flash/pro/kimi each reply OK
./scripts/create_keys.sh                     # mints general + automation keys into .env

# 6. survive reboots (no sudo needed — linger is on)
./scripts/install_systemd.sh
```

---

## 6. Daily operations

```bash
.venv/bin/python scripts/smoke_test.py      # health check all tiers
.venv/bin/python scripts/cost_report.py     # spend by model/day/key + peak-hour flag
routellm/.venv/bin/python scripts/routing_eval.py   # does the router still route correctly?
.venv/bin/python scripts/batch_job.py jobs.jsonl    # off-peak batch worker (flash only)

# recurring automation: schedule OFF-PEAK (avoid DeepSeek peak windows)
#   Peak (2x)  = Mon-Fri 6-9pm PT and 11pm-3am PT
#   Off-peak   = Mon-Fri 9-11pm PT and 3am-6pm PT + all weekend (half price)
#   Guard every job with run_offpeak.sh so it can never fire during peak:
#   30 14 * * 1-5  /home/chad/git/llmlocalsetup/scripts/run_offpeak.sh \
#                  && /home/chad/git/llmlocalsetup/.venv/bin/python \
#                     /home/chad/git/llmlocalsetup/scripts/batch_job.py jobs.jsonl
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
- **`Port already in use`** — something else owns 4000/6060; check
  `systemctl --user status llmlocalsetup-*` and `ss -tlnp`.
- **DeepSeek calls fail but kimi works** — `DEEPSEEK_API_KEY` wrong/expired in `.env`;
  gateway reloads keys on restart.
- **Postgres down** — `podman start litellm-db`; data is in the `litellm-pgdata` volume.
- **Router slow first request** — BERT checkpoint downloads from HuggingFace on first
  start (cached afterward). Set `HF_TOKEN` in `.env` to avoid rate-limit warnings.
- **Everything healthy but a model returns garbage** — check
  `scripts/routing_eval.py` output; if hard prompts route to flash, lower the router
  threshold in the model name (see section 4).

---

## 8. Where the money goes (cost controls recap)

- Explicit tiers: you pick flash/pro/kimi.
- Auto: BERT router sends ~65% to flash, ~35% to pro.
- Budgets: every key has a hard monthly cap (429 when hit).
- Automation key: flash-only, so cron/batch can't touch premium models.
- Off-peak: DeepSeek halves the (already cheapest) price outside peak windows.
- Caching: keep system prompts byte-identical → $0.0028/M cached input (50x cheaper).
