#!/usr/bin/env bash
# Hermes stack watchdog — auto-repair if Claude shutdown kills Hermes children.
# Stays alive as a systemd Type=simple service; checks every 60s.
# Tracked copy of ~/.config/systemd/user/hermes-watchdog.sh (install: see hermes/README.md).
set -u

DASHBOARD_UNIT=hermes-dashboard.service
WATCHDOG_UNIT=hermes-watchdog.service
LOGGER="systemd-cat -t hermes-watchdog"
# A dashboard start can first finish an interrupted source update (TUI, web UI
# and desktop app builds, several minutes) before it listens on 9119. Restarting
# it inside that window killed the build every minute, so the update never
# finished and each restart leaked a ~50 MB apps/desktop/.dist-build-* dir.
STARTUP_GRACE_SEC=600

log() { echo "[$(date '+%F %T')] $*" | $LOGGER 2>/dev/null || echo "[watchdog] $*"; }

# Seconds since the dashboard unit last became active (0 if unknown).
dashboard_uptime() {
    local entered now
    entered=$(systemctl --user show -p ActiveEnterTimestampMonotonic --value $DASHBOARD_UNIT 2>/dev/null)
    now=$(awk '{printf "%d", $1 * 1000000}' /proc/uptime)
    if [ -z "$entered" ] || [ "$entered" -eq 0 ]; then echo 0; return; fi
    echo $(( (now - entered) / 1000000 ))
}

while true; do
# --- Dashboard (port 9119) -------------------------------------------------
if ! systemctl --user is-active --quiet $DASHBOARD_UNIT; then
    log "dashboard unit inactive — starting it"
    systemctl --user start $DASHBOARD_UNIT && log "dashboard started OK" || log "dashboard FAILED to start"
elif ! ss -tln 2>/dev/null | grep -q ':9119 '; then
    up=$(dashboard_uptime)
    if [ "$up" -lt $STARTUP_GRACE_SEC ]; then
        log "dashboard up ${up}s, not on 9119 yet — within ${STARTUP_GRACE_SEC}s startup grace"
    else
        log "dashboard unit active ${up}s but nothing listening on 9119 — restarting unit"
        systemctl --user restart $DASHBOARD_UNIT && log "dashboard restarted OK" || log "dashboard restart FAILED"
    fi
fi

# --- Keep our own unit alive if systemd ever flags it ----------------------
systemctl --user is-active --quiet $WATCHDOG_UNIT || systemctl --user start $WATCHDOG_UNIT 2>/dev/null

sleep 60
done
