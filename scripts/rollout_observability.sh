#!/usr/bin/env bash
# One-time rollout of the LiteLLM observability stack (PR #2) on this host.
# Run AFTER the merged code is in the checkout and AFTER the shared PR #3 deploy
# steps (docs/SECURITY-MONITORING.md §8: SMTP env in monitoring/.env, fail2ban
# sudo steps). Safe to re-run: the proxy.log archive/truncate happens once
# (marker file); everything else is idempotent. See docs/OBSERVABILITY.md.
#
# Usage: ./scripts/rollout_observability.sh
#
# Downtime: the LiteLLM gateway is recreated (~20-60s) to pick up the new
# config + LITELLM_LOG env; prometheus/blackbox/grafana are recreated.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP=$(date +%Y%m%d-%H%M%S)
ENVF="$ROOT/monitoring/.env"
STATE="$HOME/.local/state"
MARK="$STATE/litellm-observability-rollout.done"
LOG="$HOME/.local/share/containers/storage/volumes/litellm_logs/_data/proxy.log"
mkdir -p "$STATE"

echo "== 1. preflight"
[ -f "$ENVF" ] || { echo "ERROR: monitoring/.env missing (cp monitoring/.env.example monitoring/.env)"; exit 1; }
grep -q '^ALERT_EMAIL_TO=.' "$ENVF" || { echo "ERROR: set ALERT_EMAIL_TO in monitoring/.env (docs/SECURITY-MONITORING.md §8 step 3)"; exit 1; }
if grep -q '^GRAFANA_SMTP_USER=.' "$ENVF"; then
  echo "  alert email: SMTP credentials present"
else
  echo "  WARNING: GRAFANA_SMTP_USER empty — alerts will evaluate but NOT email (SECURITY-MONITORING.md §7)"
fi
[ -s "$ROOT/monitoring/prometheus/bearer_token" ] || "$ROOT/scripts/refresh_bearer_token.sh"

echo "== 2. archive + truncate pre-JSON proxy.log (first run only)"
if [ ! -e "$MARK" ] && [ -s "$LOG" ]; then
  gzip -c "$LOG" > "$LOG.pre-json-$STAMP.gz"
  : > "$LOG"
  echo "  archived to $(basename "$LOG").pre-json-$STAMP.gz"
else
  echo "  skipped"
fi

echo "== 3. logrotate user timer"
mkdir -p "$HOME/.config/systemd/user"
cp "$ROOT/monitoring/logrotate/litellm-logrotate.service" "$ROOT/monitoring/logrotate/litellm-logrotate.timer" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now litellm-logrotate.timer
systemctl --user list-timers litellm-logrotate.timer --no-pager | head -2

echo "== 4. move aside git-ignored dashboards that clash with tracked/retired ones"
for f in fail2ban kopia litellm-prod-v2; do
  OLD="$ROOT/monitoring/data/dashboards/$f.json"
  if [ -e "$OLD" ]; then mv "$OLD" "$STATE/$f.json.$STAMP.bak"; echo "  moved $f.json to $STATE"; fi
done

echo "== 5. recreate litellm"
( cd "$ROOT/litellm" && podman-compose up -d --force-recreate --no-deps litellm )
for i in $(seq 1 40); do
  if curl -sf localhost:4000/health/readiness >/dev/null; then echo "  ready after ~$((i * 3))s"; break; fi
  sleep 3
done
curl -s localhost:4000/health/readiness; echo

echo "== 6. recreate monitoring services + restart promtail"
~/.local/bin/promtail -check-syntax -config.file="$ROOT/monitoring/promtail/promtail-config.yaml"
( cd "$ROOT/monitoring" && podman-compose up -d --force-recreate --no-deps prometheus blackbox grafana )
systemctl --user restart promtail
sleep 20

echo "== 7. scrape targets"
curl -s 127.0.0.1:9090/api/v1/targets | python3 -c '
import json, sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print(f"  {t[\"health\"]:7} {t[\"labels\"][\"job\"]:15} {t[\"scrapeUrl\"]} {t[\"lastError\"][:80]}")'

touch "$MARK"
cat <<EOF
== done
Next:
  1. generate traffic:  (set -a; . litellm/.env; set +a; LITELLM_MODELS="flash smart or-lite-qwen" .venv/bin/python scripts/smoke_test.py)
  2. verify widgets:    ./scripts/verify_dashboard.py --alerts --from now-1h
  3. test email:        Grafana -> Alerting -> Contact points -> email-alerts -> Test
  4. record results in docs/OBSERVABILITY.md "Verification log"
EOF
