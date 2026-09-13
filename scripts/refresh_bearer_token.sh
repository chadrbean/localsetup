#!/usr/bin/env bash
# Refresh monitoring/prometheus/bearer_token from litellm/.env (LITELLM_MASTER_KEY).
# Run whenever the master key rotates, or after a fresh clone (the token file
# is git-ignored). Uses printf to avoid echoing the key / putting it in argv.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$ROOT/litellm/.env"; set +a
: "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY not set in litellm/.env}"
umask 077
mkdir -p "$ROOT/monitoring/prometheus"
printf '%s' "$LITELLM_MASTER_KEY" > "$ROOT/monitoring/prometheus/bearer_token"
# 600 is fine: the prometheus container runs as user "0" (rootless podman ->
# host uid 1000, this file's owner). As the image default `nobody` it could
# NOT read the file and the litellm target silently went down (2026-09-11).
chmod 600 "$ROOT/monitoring/prometheus/bearer_token"
echo "wrote $(wc -c < "$ROOT/monitoring/prometheus/bearer_token") bytes to monitoring/prometheus/bearer_token"
