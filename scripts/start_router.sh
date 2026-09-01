#!/usr/bin/env bash
# Start the RouteLLM auto-router (flash <-> pro) on :6060.
# Router: bert, threshold 0.44878 (calibrated 2026-08-31, ~35% strong-model calls).
# strong/weak use the "openai/" provider prefix so RouteLLM's internal litellm
# forwards them through our LiteLLM proxy (--base-url/--api-key).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/routellm/.venv/bin:$PATH"
set -a; source .env; set +a
export OPENAI_API_KEY="$LITELLM_MASTER_KEY"   # needed at import time (openai client side-effect)
export OPENAI_API_BASE="http://localhost:4000/v1"
exec routellm/.venv/bin/python -m routellm.openai_server \
  --routers bert --config routellm/config.yaml \
  --strong-model openai/pro --weak-model openai/flash \
  --base-url http://localhost:4000/v1 --api-key "$LITELLM_MASTER_KEY" \
  --port 6060
