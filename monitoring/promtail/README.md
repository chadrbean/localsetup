# Promtail — log shipper for Loki

**Runs natively as a systemd user service, NOT in the monitoring pod.**
Same structural constraint as fail2ban: rootless podman can't read
`/var/log/fail2ban.log` (owned `root:adm`, GID 4 is outside the subordinate-GID
map for user `chad`). The Promtail binary runs on the host as `chad`, who is in
the `adm` group, so it can tail the file without sudo.

Kopia CLI logs (`~/.cache/kopia/cli-logs/*.log`) are `chad:chad` — no GID issue
there, but consolidating both sources into one Promtail is simpler.

## Architecture

```
/var/log/fail2ban.log ──▶┐
                          ├──▶ Promtail (:9190, native systemd user svc)
~/.cache/kopia/cli-logs/*.log ─▶┘           │
                                             │ push (HTTP)
                                             ▼
                                  Loki (:3100, container, pod_monitoring)
```

## Scrape jobs

| Job | Source | Labels (bounded) | Structured metadata (unbounded) |
|---|---|---|---|
| `fail2ban` | `/var/log/fail2ban.log` | `logger`, `level`, `jail`, `action` (`Found`/`Ban`/`Unban`/`Restore Ban`/`AlreadyBanned`) | `ip` |
| `traefik` | `../../traefik/logs/access.log` (JSON) | `status`, `method`, `router` | `req_host`, `path` |
| `kopia` | `~/.cache/kopia/cli-logs/*.log` (not `latest.log`) | `level`, `component`, `event`, `source`, `op` | — |

**Cardinality rule:** never make an attacker-controlled value (IP, Host header,
path) a Loki label — each distinct value creates a new stream. Put it in
`structured_metadata`; LogQL still filters and groups on it
(`{job="fail2ban"} | ip="1.2.3.4"`, `sum by (ip) (...)`). The `ip` label used
to be a label and had grown to one stream per attacker.

## Kopia events (volume control)

Kopia logs snapshot lifecycle at **DEBUG**, and its file log is huge (was
~50 MB / 3 h, mostly per-file lines — now cut at the source by the global
policy `--log-entry-snapshotted=0 --log-entry-ignored=0`). The pipeline keeps
only an **allow-list** of lines and labels each with `event`:

| `event` | Kopia line | Other labels / json fields |
|---|---|---|
| `snapshot_start` | `kopia/server uploading <user@host:path>` | `source` |
| `snapshot_finished` | `kopia/server finished uploading <src>` (success **and** failure) | `source` |
| `snapshot_summary` | `uploader snapshotted directory {"path":"."…}` — root done, no error | `dur,size,files,dirs,errors` |
| `file_error` | `snapshotted file/directory/symlink` carrying `"error":"…"` | `path,error` |
| `storage` | `kopia/repo [STORAGE] PutBlob/GetBlob/ListBlobs/DeleteBlob` | `op`; `duration,length,error` |
| `retention_delete` | `kopia/snapshot/policy deleting …` | — |
| `maintenance` | `maintenance` / `snapshotgc` component lines | — |
| `error` | any `WARN`/`ERROR`/`FATAL` line | — |

Kopia's timestamp becomes the Loki timestamp, and `latest.log` (a symlink to
the active file) is excluded so lines aren't ingested twice. Full signal →
alert → email picture: [docs/KOPIA-MONITORING.md](../../docs/KOPIA-MONITORING.md).

**Test pipeline changes with a dry run** — `-check-syntax` does not validate
match selectors (Promtail 3.1 rejects LogQL backtick strings in them):

```bash
# temp config containing only the kopia job, then feed real lines through it
~/.local/bin/promtail -stdin -dry-run -config.file /tmp/kopia-only.yaml \
  < ~/.cache/kopia/cli-logs/latest.log | head
```

**Backfill** after changing the Kopia pipeline (Loki keeps/accepts 7 days):

```bash
systemctl --user stop promtail
# delete the ~/.cache/kopia/cli-logs/* entries under `positions:` in
#   ~/.local/share/promtail/positions.yaml
systemctl --user start promtail
```

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