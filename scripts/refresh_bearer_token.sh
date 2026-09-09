#!/usr/bin/env bash
# Refresh monitoring/prometheus/bearer_token from ../.env (LITELLM_MASTER_KEY).
# Run whenever the master key rotates, or after a fresh clone (the token file
# is git-ignored). Uses printf to avoid echoing the key / putting it in argv.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$ROOT/.env"; set +a
: "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY not set in .env}"
umask 077
mkdir -p "$ROOT/monitoring/prometheus"
printf '%s' "$LITELLM_MASTER_KEY" > "$ROOT/monitoring/prometheus/bearer_token"
chmod 600 "$ROOT/monitoring/prometheus/bearer_token"
echo "wrote $(wc -c < "$ROOT/monitoring/prometheus/bearer_token") bytes to monitoring/prometheus/bearer_token"
