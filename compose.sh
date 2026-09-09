#!/usr/bin/env bash
# Compose wrapper for localsetup projects — manage the litellm/ and traefik/
# compose stacks through podman-compose (this box's compose engine; no docker
# installed — the `docker` command was podman-docker's shim and is removed).
#
# The stacks run podless (docker-compose-v2-style containers). podman-compose
# 1.2.0 creates a pod when it builds a stack, so:
#   - `./compose.sh <p> up -d`  brings the project up as a POD (pod-style
#     container names) — fine for a fresh bring-up;
#   - `./compose.sh <p> ps` shows nothing for a podless/existing stack
#     (1.2.0 quirk) — use `podman ps` / `podman pod ps` for status.
# The wrapper always loads the repo .env so ${REDIS_PASSWORD} etc. resolve.
#
# Usage:   ./compose.sh <project> <args...>     e.g. ./compose.sh litellm up -d
#          ./compose.sh litellm config
#          ./compose.sh traefik down
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${1:?usage: compose.sh <litellm|traefik> <podman-compose args...>}"
shift

case "$PROJECT" in
  litellm) DIR="$ROOT/litellm"; FILE=docker-compose.yml ;;
  traefik) DIR="$ROOT/traefik"; FILE=compose.yaml ;;
  *) echo "unknown project '$PROJECT' (use litellm or traefik)" >&2; exit 2 ;;
esac

cd "$DIR"
# shellcheck disable=SC1091
set -a; source "$ROOT/.env"; set +a
exec podman-compose -f "$FILE" "$@"
