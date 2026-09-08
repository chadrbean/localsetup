#!/usr/bin/env bash
# Compose wrapper for localsetup projects — the ONLY supported way to manage
# the litellm/ and traefik/ compose stacks.
#
# Why: this box runs podman; `docker` is an emulated CLI and `podman-compose`
# also exists. The two compose engines write different network labels and fight
# over the same project network (docker compose up fails with "network
# litellm_default ... incorrect label" if podman-compose created it first).
# Pin everything to `docker compose` and always pass the repo .env so
# ${REDIS_PASSWORD} and friends interpolate correctly.
#
# Usage:   ./compose.sh <project> <args...>     e.g. ./compose.sh litellm ps
#          ./compose.sh litellm up -d
#          ./compose.sh litellm logs -f
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${1:?usage: compose.sh <litellm|traefik> <docker compose args...>}"
shift

case "$PROJECT" in
  litellm) DIR="$ROOT/litellm"; FILE=docker-compose.yml ;;
  traefik) DIR="$ROOT/traefik"; FILE=compose.yaml ;;
  *) echo "unknown project '$PROJECT' (use litellm or traefik)" >&2; exit 2 ;;
esac

cd "$DIR"
# shellcheck disable=SC1091
set -a; source "$ROOT/.env"; set +a
exec docker compose -f "$FILE" "$@"
