#!/usr/bin/env bash
# Fetch the official LiteLLM Grafana dashboard ("LiteLLM Prod v2", BerriAI/litellm
# cookbook) into monitoring/data/dashboards/ (git-ignored). Idempotent.
# Usage: ./scripts/fetch_litellm_dashboard.sh
# After fetching: podman restart monitoring_grafana  (provisioning reload).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/monitoring/data/dashboards"
SRC="https://raw.githubusercontent.com/BerriAI/litellm/main/cookbook/litellm_proxy_server/grafana_dashboard/dashboard_v2/grafana_dashboard.json"
mkdir -p "$OUT"
echo "fetching LiteLLM Prod v2 dashboard..."
code=$(curl -sfL -o "$OUT/litellm-prod-v2.json" -w '%{http_code}' "$SRC") || { echo "ERROR: fetch failed (http ${code:-?})"; exit 1; }
python3 - "$OUT/litellm-prod-v2.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
assert d.get('title'), f"{p}: not a Grafana dashboard JSON"
print(f"saved: {p}  (title: {d['title']}, panels: {len(d.get('panels', []))})")
PY
echo "next: podman restart monitoring_grafana"
