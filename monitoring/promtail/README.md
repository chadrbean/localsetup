# Promtail — log shipper for Loki

**Runs natively as a systemd user service, NOT in the monitoring pod.**
Same structural constraint as fail2ban: rootless podman can't read
`/var/log/fail2ban.log` (owned `root:adm`, GID 4 is outside the subordinate-GID
map for user `chad`). The Promtail binary runs on the host as `chad`, who is in
the `adm` group, so it can tail the file without sudo.

Kopia CLI logs (`~/.cache/kopia/cli-logs/*.log`), the Traefik access log and the
LiteLLM `proxy.log` (in the `litellm_logs` podman volume — rootless-podman root is
`chad` on the host) have no GID issue, but consolidating every source into one
Promtail is simpler.

## Architecture

```
/var/log/fail2ban.log ─────────────────────▶┐
traefik/logs/access.log ───────────────────▶┤
litellm_logs volume /_data/proxy.log ──────▶├──▶ Promtail (:9190, native systemd user svc)
~/.cache/kopia/cli-logs/*.log ─────────────▶┘           │
                                             │ push (HTTP)
                                             ▼
                                  Loki (:3100, container, pod_monitoring)
```

## Scrape jobs

| Job | Source | Labels (bounded) | Structured metadata (unbounded) |
|---|---|---|---|
| `fail2ban` | `/var/log/fail2ban.log` | `logger`, `level`, `jail`, `action` (`Found`/`Ban`/`Unban`/`Restore Ban`/`AlreadyBanned`) | `ip` |
| `traefik` | `../../traefik/logs/access.log` (JSON) | `status`, `method`, `router` | `req_host`, `path` |
| `litellm` | `litellm_logs` volume `proxy.log` (JSON via `json_logs`) | `level` | — (prompt text is never logged) |
| `kopia` | `~/.cache/kopia/cli-logs/*.log` | `level`, `component` | — |

**Cardinality rule:** never make an attacker-controlled value (IP, Host header,
path) a Loki label — each distinct value creates a new stream. Put it in
`structured_metadata`; LogQL still filters and groups on it
(`{job="fail2ban"} | ip="1.2.3.4"`, `sum by (ip) (...)`). The `ip` label used
to be a label and had grown to one stream per attacker.

The `litellm` job drops `/health/*` and `/metrics` access lines and exports three
log-derived counters on `:9190`: `promtail_custom_litellm_classifier_failures_total`,
`promtail_custom_litellm_secrets_redacted_total`, `promtail_custom_litellm_log_errors_total`
(used by the LiteLLM Gateway dashboard and the Smart Router Classifier Failing alert).

## Volume control

Kopia produces ~50 MB of log every ~3 hours, ~99.9% of which is DEBUG-level
`uploader snapshotted directory` entries. The Promtail pipeline drops
`DEBUG`-level lines at the tail stage — they never leave the host — with ONE
exception: the per-source summary line with `{"path":"."}`, which is the only
record that a snapshot finished (with its size, duration, file and error
counts). That's a few lines per hour and drives the Kopia dashboard and the
`Kopia Backup Warning/Stale` alerts.

## Install

1. Download the Promtail binary (same version as the Loki image, currently
   `3.1.1`):

```bash
cd /tmp
curl -sLO "https://github.com/grafana/loki/releases/download/v3.1.1/promtail-linux-amd64.zip"
unzip promtail-linux-amd64.zip
install -m 755 promtail-linux-amd64 /home/chad/.local/bin/promtail
rm promtail-linux-amd64 promtail-linux-amd64.zip
```

2. Set up the service file:

```bash
mkdir -p ~/.config/systemd/user ~/.local/share/promtail
cp promtail.service ~/.config/systemd/user/promtail.service
systemctl --user daemon-reload
systemctl --user enable --now promtail
systemctl --user status promtail
```

3. Enable lingering so the service starts at boot (even before you log in
   graphically):

```bash
loginctl enable-linger chad
```

## Verify

```bash
# Promtail self-metrics
curl 127.0.0.1:9190/metrics | grep promtail_

# Validate config before restarting
~/.local/bin/promtail -check-syntax -config.file=promtail-config.yaml

# Loki should see the client
curl -s http://127.0.0.1:3100/loki/api/v1/labels | jq .
# Expect: job, host, logger, level, jail, action, status, method, router, component
# (NOT ip / req_host / path — those are structured metadata)
# LiteLLM stream + log-derived counters:
#   curl -s 127.0.0.1:3100/loki/api/v1/label/job/values   # includes litellm
#   curl -s 127.0.0.1:9190/metrics | grep promtail_custom_litellm

# Live log query (fail2ban bans in last hour, per jail):
# sum by (jail) (count_over_time({job="fail2ban", action="Ban"} [1h]))
# Top attacking IPs (structured metadata):
# topk(10, sum by (ip) (count_over_time({job="fail2ban", action="Found"} | ip!="" [24h])))
```

## Daily ops

| Action | Command |
|---|---|
| Status | `systemctl --user status promtail` |
| Restart | `systemctl --user restart promtail` |
| Logs | `journalctl --user -u promtail -f` |
| Stop | `systemctl --user stop promtail` |
| Disable | `systemctl --user disable --now promtail` |

The promtail systemd user service DOES NOT write to disk logs — all diagnostic
output goes to journald, readable with the `journalctl` command above.