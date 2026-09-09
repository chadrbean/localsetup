# Vast.ai GPU rentals — adding a model to LiteLLM

How to wire a rented vast.ai GPU box (Ollama or vLLM) into this LiteLLM gateway as a
model Hermes can reach. Written 2026-09-01 after wiring (and unwiring) two rentals.
Cost is the hourly rental, not per-token — so `model_info` costs are set to `0`.

**TL;DR for rentals**: probe the box, get its true context window, add the LiteLLM
entry with the exact model id the server reports, restart the gateway, add the model
to the virtual key allowlist, and set `model_overrides` in Hermes so the picker shows
the truth. A box running a model with <64K native context **cannot be the main Hermes
agent model** — plan around that before renting.

---

## 1. What vast.ai gives you

Every instance exposes one or more **port mappings** (container port → public
IP:port). Two common images:

| Image | Backend | Auth on public port | How to find the model API |
|-------|---------|--------------------|---------------------------|
| `vastai/ollama` / openwebui | Ollama | Bearer token (the `?token=` value) | `GET /api/tags` or `GET /v1/models` with `Authorization: Bearer <token>` |
| `vastai/vllm` | vLLM | Portal/Caddy token or Basic | read `/etc/vast_agents/vllm.md` on the box; internal API on `127.0.0.1:18000` |

The instance page shows "Port Mappings" (container → public). The **`OPEN_BUTTON_TOKEN`**
and **`OPEN_BUTTON_PORT`** in the launch env are for the vast portal web UI — the real
API auth token lives in `/etc/environment` on the box (e.g. `OPEN_BUTTON_TOKEN="<hex>"`)
and is what Caddy accepts as `Authorization: Bearer <hex>` or `?token=<hex>`.

**vLLM boxes** (vastai/vllm image): the actual API is internal on `127.0.0.1:18000`
(`/v1` = OpenAI base). Supervisor services: `vllm`, `caddy`, `model-ui`, `instance_portal`.
External Caddy routes mostly to the portal/Model UI (HTML), not the raw API — the
**reliable path is an SSH tunnel to 18000**. Capabilities manifest:
`curl -s http://localhost:11111/capabilities/endpoints` (run on the box).

**Ollama boxes**: the public mapped port usually IS the Ollama API directly (token as
Bearer works on `/api/tags`, `/v1/models`, `/v1/chat/completions`).

---

## 2. Probe the box first (read-only)

```bash
# Ollama-style public port:
curl -s http://IP:PORT/api/tags -H "Authorization: Bearer $TOKEN"        # model list
curl -s http://IP:PORT/v1/models -H "Authorization: Bearer $TOKEN"       # OpenAI view
curl -s http://IP:PORT/api/version -H "Authorization: Bearer $TOKEN"

# vLLM via tunnel (see §4):
curl -s http://localhost:18000/v1/models      # → read max_model_len = TRUE context
```

**Always capture the exact model id the server reports** — Ollama reports
`qwen3.5:35b`, vLLM reports `Qwen/Qwen3.5-9B`. LiteLLM sends whatever model id you
put after the provider prefix; if it doesn't match the server's id you get
`NotFoundError: The model 'X' does not exist`.

Get the true context window from the box BEFORE wiring anything:
- vLLM: `/v1/models` → `max_model_len` field (this is the server's hard cap)
- Ollama: `ollama show <model>` on the box, or the model card

---

## 3. The 64K Hermes floor (critical)

Hermes **hard-rejects** any main agent model with a context window under 64K
(`MINIMUM_CONTEXT_LENGTH`, checked at agent init). The picker will happily show a
32K model, then `hermes` fails to start with:

> Model X has a context window of 32,000 tokens, which is below the minimum 64,000
> required by Hermes Agent.

Consequences:
- **LiteLLM's `/v1/models` does NOT report context to Hermes.** Without an explicit
  override, Hermes assumes 256K — so a small-context model *looks* fine in the picker
  and only dies at agent init (or worse: Hermes sends `max_tokens` larger than the
  server allows → HTTP 400, misread as "context exceeded" → compression spiral).
- 9B-class models are natively 32K → never main-agent material. Use them for
  one-off/delegated tasks only, or skip them.
- 14B+ / MoE models (Qwen 27B+, Qwen3.5-35B MoE) are 128K–262K → fine.

---

## 4. SSH tunnel (vLLM boxes)

The vLLM API binds `127.0.0.1:18000` on the box — tunnel it:

```bash
ssh -i ~/.ssh/vast_ai -p <SSH_PORT> -L 18000:localhost:18000 root@ssh5.vast.ai
# -N keeps it silent; add -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes
# Run as a background process / systemd user unit so it survives the session.
```

Then `http://localhost:18000/v1` is the OpenAI base (no auth needed locally).
NOTE: another process may already hold a local port — check with `ss -tlnp | grep :18000`.
The gateway model entry then points at `http://localhost:18000/v1` and **only works
while the tunnel is up**.

---

## 5. LiteLLM config entry (`litellm/config.yaml`)

Add to `model_list:` (see the file for the live pattern):

```yaml
  # --- Vast.ai rental (backend; cost = hourly rental, not per-token) ---
  # <what/where>; context N; reachable only while the rental/tunnel is up.
  # URL+token hardcoded: public rental, no secrets; IP/port change on re-rent.
  - model_name: <alias>              # e.g. vast  — what Hermes calls it
    litellm_params:
      model: ollama_chat/<exact-server-model-id>   # Ollama
      # model: openai/<exact-server-model-id>      # vLLM — match server id EXACTLY
      api_base: http://IP:PORT                      # public port, or localhost tunnel
      api_key: <token-or-dummy>                    # Ollama: real token; vLLM tunnel: dummy
    model_info:
      input_cost_per_token: 0
      output_cost_per_token: 0
```

Provider prefix rules:
- `ollama_chat/<tag>` → Ollama (chat API). Use `ollama/` for the legacy completions API.
- `openai/<id>` → OpenAI-compatible (vLLM). The id after the slash is sent verbatim —
  `openai/Qwen/Qwen3.5-9B`, NOT a lowercased alias.

vLLM reasoning models (Qwen3.5 etc.) burn tokens on chain-of-thought with no ceiling
unless disabled — the vast template's `--reasoning-parser qwen3` has no budget cap:

```yaml
      extra_body:
        chat_template_kwargs:
          enable_thinking: false      # disable CoT; verified on vLLM 0.28 / Qwen3.5
```

Restart + verify:
```bash
cd ~/git/localsetup && ./compose.sh litellm restart litellm
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

---

## 6. Virtual key allowlist (LiteLLM)

The gateway filters `/v1/models` per virtual key. Hermes uses `LITELLM_GENERAL_KEY`
(alias "general") — until the new model is added to ITS allowlist, Hermes never sees it:

```bash
cd ~/git/localsetup && set -a && source .env && set +a
curl -s http://localhost:4000/key/update \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d "{\"key\":\"$LITELLM_GENERAL_KEY\",\"models\":[\"flash\",\"pro\",\"kimi\",\"auto\",\"<alias>\"]}"
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer $LITELLM_GENERAL_KEY"  # verify
```

Also test a chat through the gateway with the general key before touching Hermes.

---

## 7. Hermes side (config + picker)

Two files under `~/.hermes/`:

**a) `model_overrides` — set the TRUE context window** (so the picker shows it and
agent init doesn't assume 256K):

```yaml
model_overrides:
  gateway:                      # provider name (the LiteLLM provider block)
    <alias>:
      context_window: <true-ctx>   # e.g. 262144 for the 35B, 32000 for a 32K box
```

Note: Hermes enforces ≥64K for the main agent model — a 32K box can still be listed
here (subagent/one-off use) but will fail as the primary model.

**b) provider model catalog** (`providers.gateway.models` in the same config) so the
picker row includes it. The picker lists models per provider from: explicit `models:`
list/dict, then a live `/v1/models` probe cached ~1h in
`~/.hermes/provider_models_cache.json`. Add the alias to the provider's `models:`
dict (`<alias>: {}`) and/or refresh the cache entry
(`custom:http://localhost:4000/v1` → add the id) to avoid a stale 1h picker.

Aliases are optional — `model.aliases.<name>: gateway/<alias>` only powers `/model
<name>` shorthand, NOT the picker list. Skip unless you want a short name.

---

## 8. Cleanup (removing a rental)

1. Remove the `model_list` entry from `litellm/config.yaml`; restart the gateway.
2. Remove the alias from the virtual key allowlist (§6, same call minus the model).
3. Remove the Hermes config bits: `model.aliases` entry, the provider `models:`
   entry + `model_overrides.gateway.<alias>` block, and refresh
   `provider_models_cache.json`.
4. Kill any SSH tunnel; stop/delete the vast instance.

---

## 9. Pitfalls learned the hard way

- `hermes config set` **stringifies** nested JSON values (`models: '{"a": {}}'`) and
  **mangles keys with colons** — edit `~/.hermes/config.yaml` directly (it is
  write-protected from agent patches but fine by hand / small python) or verify after
  every set.
- Auto-router custom tiers: LiteLLM's complexity router validates tier names against
  a FIXED set (SIMPLE/MEDIUM/COMPLEX/REASONING) — a 5th custom tier needs
  `tier_definitions` + `fallback_tier`, and custom sets are incompatible with
  `classification_rubric: agentic`. Don't bolt VAST onto the router; add the model as
  a plain entry instead.
- External vLLM port returns HTML "Loading…" after auth — that's the Model UI/portal,
  not the API. Tunnel to 18000.
- vast.ai instance IP:port changes every re-rent. Hardcode current values in the
  config; the comment should say they'll change.
- The `?token=` in a vast URL is a browser-session/link token for the portal; the API
  bearer token is the `OPEN_BUTTON_TOKEN` from `/etc/environment` on the box.
- vLLM max_model_len is set at server launch (`--max-model-len` in VLLM_ARGS, template
  default 32000). Raising it past the model's native window needs YaRN rope-scaling
  and degrades quality — don't fake a bigger context in Hermes than the server allows
  or every long request 400s.

## Chad Section - Models
Model	Exact vLLM Model Name	Quantization
Gemma 4 31B	google/gemma-4-31B-it	BF16 (needs 2x GPU) or --quantization awq for single GPU
Gemma 4 26B MoE	google/gemma-4-26B-A4B-it	BF16 (fits 1x 80GB)
Qwen 3.6 35B-A3B	Qwen/Qwen3.6-35B-A3B	BF16 or Qwen/Qwen3.6-35B-A3B-FP8
GLM-4.7-Flash	zai-org/GLM-4.7-Flash	BF16
Devstral Small 2	mistralai/Devstral-Small-2-24B-Instruct-2512	BF16
Gemma 3 27B	google/gemma-3-27b-it	BF16 or GPTQ
Qwen 3 32B	Qwen/Qwen3-32B	AWQ: Qwen/Qwen3-32B-AWQ