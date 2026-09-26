#!/usr/bin/env bash
# Deploy the tracked Alloy agent config to a LAN desktop and verify it end to end.
#
#   monitoring/alloy/deploy.sh stage   copy install.sh + drop-in + config to the
#                                      remote /tmp/alloy-* (then run install.sh with sudo)
#   monitoring/alloy/deploy.sh push    install config.alloy into ~/.config/alloy (no
#                                      sudo), hot-reload Alloy, then check
#   monitoring/alloy/deploy.sh check   service active, config + drop-in match the repo,
#                                      all components healthy, metrics and Kopia logs
#                                      arriving in this host's Prometheus / Loki
#
# Remote: ALLOY_REMOTE_HOST (default: zuriel, Zuriel's workstation). See docs/HOSTS.md.
set -euo pipefail

cd "$(dirname "$0")"
REMOTE=${ALLOY_REMOTE_HOST:-zuriel}
# The desktop SSH agent can refuse to sign non-interactively; use the key file.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o IdentityAgent=none -o IdentitiesOnly=yes)
PROM=${PROM_URL:-http://127.0.0.1:9090}
LOKI=${LOKI_URL:-http://127.0.0.1:3100}

remote() { ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"; }
md5() { md5sum | cut -d' ' -f1; }

stage() {
    scp -q "${SSH_OPTS[@]}" install.sh "$REMOTE:/tmp/alloy-install.sh"
    scp -q "${SSH_OPTS[@]}" alloy.service.d/override.conf "$REMOTE:/tmp/alloy-override.conf"
    scp -q "${SSH_OPTS[@]}" config.alloy "$REMOTE:/tmp/alloy-config.alloy"
    echo "staged. Now run (asks for $REMOTE's sudo password):"
    echo "  ssh -t $REMOTE 'sudo bash /tmp/alloy-install.sh \$(whoami)'"
}

push() {
    # shellcheck disable=SC2016  # expanded on the remote host
    remote 'f=~/.config/alloy/config.alloy; [ -f $f ] && cp -p $f $f.prev; mkdir -p ~/.config/alloy'
    scp -q "${SSH_OPTS[@]}" config.alloy "$REMOTE:.config/alloy/config.alloy"
    # A bad config is rejected by /-/reload and the old one keeps running.
    if remote 'curl -fsS -X POST http://127.0.0.1:12345/-/reload'; then
        echo "pushed + reloaded config.alloy"
    else
        echo "RELOAD FAILED: previous config still running (~/.config/alloy/config.alloy.prev)" >&2
        return 1
    fi
    check
}

check() {
    local rc=0 host want got
    host=$(remote hostname)

    [ "$(remote 'systemctl is-active alloy' || true)" = active ] \
        && echo "ok    $REMOTE alloy.service active" || { echo "FAIL  $REMOTE alloy.service not active"; rc=1; }

    [ "$(remote 'md5sum < ~/.config/alloy/config.alloy' | cut -d' ' -f1)" = "$(md5 < config.alloy)" ] \
        && echo "ok    $REMOTE config.alloy matches repo" || { echo "DRIFT $REMOTE config.alloy (push)"; rc=1; }

    # shellcheck disable=SC2016  # expanded on the remote host
    want=$(sed -e "s|@USER@|$(remote whoami)|g" -e "s|@HOME@|$(remote 'echo $HOME')|g" alloy.service.d/override.conf | md5)
    got=$(remote 'md5sum < /etc/systemd/system/alloy.service.d/override.conf' 2>/dev/null | cut -d' ' -f1 || true)
    [ "$got" = "$want" ] && echo "ok    $REMOTE drop-in matches repo" || { echo "DRIFT $REMOTE drop-in (stage + install.sh)"; rc=1; }

    got=$(remote 'curl -fsS http://127.0.0.1:12345/api/v0/web/components' 2>/dev/null \
        | python3 -c 'import json,sys; print(" ".join(c["localID"] for c in json.load(sys.stdin) if c["health"]["state"] != "healthy"))' 2>/dev/null || echo "unreachable")
    [ -z "$got" ] && echo "ok    $REMOTE all components healthy" || { echo "FAIL  $REMOTE unhealthy: $got"; rc=1; }

    # End to end: fresh samples in Prometheus, Kopia lines in Loki (24h window;
    # an idle PC legitimately has none, so this one only warns).
    got=$(curl -fsS "$PROM/api/v1/query" --data-urlencode "query=time() - timestamp(node_uname_info{host=\"$host\"})" \
        | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(int(float(r[0]["value"][1])) if r else "none")')
    if [ "$got" != none ] && [ "$got" -lt 300 ]; then echo "ok    prometheus has $host metrics (${got}s old)"
    else echo "FAIL  prometheus: no fresh node_uname_info{host=\"$host\"} ($got)"; rc=1; fi

    got=$(curl -fsS -G "$LOKI/loki/api/v1/query" --data-urlencode "query=sum(count_over_time({job=\"kopia\", host=\"$host\"}[24h]))" \
        | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)')
    [ "$got" != 0 ] && echo "ok    loki has $got Kopia lines from $host (24h)" \
        || echo "warn  loki: no Kopia lines from $host in 24h (PC off, or no snapshot since install)"
    return $rc
}

case "${1:-check}" in
    stage) stage ;;
    push) push ;;
    check) check ;;
    *) echo "usage: $0 [stage|push|check]" >&2; exit 2 ;;
esac
