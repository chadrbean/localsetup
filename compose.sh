#!/usr/bin/env bash
# Compose wrapper for localsetup projects — manage the litellm/ and traefik/
# compose stacks through podman-compose (this box's compose engine; no docker
# installed — the `docker` command was podman-docker's shim and is removed).
#
# The stacks run as PODS (podman-compose 1.2.0 creates a pod per stack):
#   - `./compose.sh <p> up -d`  brings the project up as pod_<p> with
#     pod-style container names (e.g. litellm_db, litellm_litellm_1);
#   - `./compose.sh <p> ps` shows nothing for a running stack (1.2.0 quirk) —
#     use `podman ps` / `podman pod ps` for status.
# Migrated 2026-09-08 from a podless bring-up: `down` then `up -d` rebuilds
# the stack inside a pod; named volumes (postgres_data, redis_data) survive.
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
  monitoring) DIR="$ROOT/monitoring"; FILE=docker-compose.yml ;;
  *) echo "unknown project '$PROJECT' (use litellm, traefik or monitoring)" >&2; exit 2 ;;
esac

cd "$DIR"
# shellcheck disable=SC1091
set -a; source "$ROOT/.env"; set +a
exec podman-compose -f "$FILE" "$@"
