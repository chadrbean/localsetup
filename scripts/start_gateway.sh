#!/usr/bin/env bash
# Start the LiteLLM gateway (no docker — direct venv run).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/.venv/bin:$PATH"   # prisma CLI needs this for DB migrations at startup
set -a; source .env; set +a
exec .venv/bin/litellm --config litellm/config.yaml --port 4000
