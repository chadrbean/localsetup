#!/usr/bin/env bash
# Create per-consumer LiteLLM virtual keys (stored in .env, git-ignored)
# and run the budget-enforcement test.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
BASE="${LITELLM_BASE:-http://localhost:4000}"
AUTH="Authorization: Bearer $LITELLM_MASTER_KEY"
CT="Content-Type: application/json"

gen_key () {
  local alias="$1" models="$2" budget="$3"
  curl -s -X POST "$BASE/key/generate" -H "$AUTH" -H "$CT" \
    -d "{\"models\": $models, \"max_budget\": $budget, \"budget_duration\": \"1mo\", \"key_alias\": \"$alias\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])"
}

ensure_env () {  # idempotent append
  local name="$1" val="$2"
  grep -q "^${name}=" .env || printf '%s=%s\n' "$name" "$val" >> .env
}

ensure_key () {  # create only if not already in .env
  local alias="$1" models="$2" budget="$3" envname="$4"
  if grep -q "^${envname}=" .env; then
    echo "$alias key already exists (${envname} in .env) — skipping"
    return
  fi
  local key
  key=$(gen_key "$alias" "$models" "$budget")
  ensure_env "$envname" "$key"
  echo "$alias created → ${envname} stored in .env"
}

echo "== creating keys =="
ensure_key general '["flash","pro","kimi","auto"]' 50.0 LITELLM_GENERAL_KEY
ensure_key automation '["flash"]' 10.0 LITELLM_AUTOMATION_KEY
# OpenRouter tier: dedicated key, allowlisted to the OpenRouter models only,
# $15/mo hard budget (guardrail). Used by Hermes gateway-or aliases
# (gpt5/kimi-code/lite/lite-deep/plan/plan-cheap — see litellm/litellm-config.yaml
# for the or-lite-*/or-plan-* model_list entries these map to).
# `zai-free` (Z.AI glm-4.7-flash, $0) is deliberately ONLY on this key, never on
# LITELLM_GENERAL_KEY. It is heavily rate limited (measured 2/10 at ~10 req/min), so
# keeping it off the general key stops Hermes' default `gateway` path from ever landing
# on it and stalling. Reach it deliberately via `/model free`.
ensure_key openrouter '["gpt5","kimi-code","kimi","or-lite-glm","or-lite-qwen","or-plan-qwen","or-plan-minimax","zai-free"]' 15.0 LITELLM_OPENROUTER_KEY

echo
echo "== enforcement test: \$0.0001 budget key, calling kimi =="
THROW=$(gen_key "throwaway-$(date +%s)" '["kimi"]' 0.0001)
echo "call #1 (allowed — records spend):"
curl -s -o /tmp/enforce1.out -w "  HTTP %{http_code}\n" -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $THROW" -H "$CT" \
  -d '{"model":"kimi","messages":[{"role":"user","content":"hello"}]}'
echo "call #2 (must be rejected — over budget):"
curl -s -o /tmp/enforce2.out -w "  HTTP %{http_code}\n" -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $THROW" -H "$CT" \
  -d '{"model":"kimi","messages":[{"role":"user","content":"hello again"}]}'
echo "  body:"; head -c 200 /tmp/enforce2.out; echo
echo
echo "== test: automation key can only reach flash =="
set -a; source .env; set +a   # pick up freshly generated keys
curl -s -o /tmp/auto.out -w "automation->kimi: HTTP %{http_code}\n" -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_AUTOMATION_KEY" -H "$CT" \
  -d '{"model":"kimi","messages":[{"role":"user","content":"hello"}]}'
head -c 200 /tmp/auto.out; echo
curl -s -o /tmp/auto2.out -w "automation->flash: HTTP %{http_code}\n" -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_AUTOMATION_KEY" -H "$CT" \
  -d '{"model":"flash","messages":[{"role":"user","content":"hello"}]}'
