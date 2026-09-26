# monitoring/alloy — agent for other LAN desktops

[Grafana Alloy](https://grafana.com/docs/alloy/) runs on each desktop that isn't
this host (today: Zuriel's workstation, `wkspikaoszuriel`). It ships that
desktop's Kopia logs to this host's Loki and its host metrics to this host's
Prometheus, so it shows up in the same Grafana dashboards and alerts. The host
inventory and every deployed file are in [`docs/HOSTS.md`](../../docs/HOSTS.md).

```
wkspikaoszuriel                                   wkspikaoschad (192.168.1.30)
 alloy.service (User=zuriel)
  ├ ~/.cache/kopia/cli-logs/*.log ─ loki.write ──────▶ Loki :3100 ─┐
  └ unix + self exporters ──────── remote_write ────▶ Prometheus :9090 ─┴▶ Grafana
                                    (nftables: only allow-listed hosts; monitoring/firewall/)
```

| File | Deployed to | How |
|---|---|---|
| `config.alloy` | `~/.config/alloy/config.alloy` | `deploy.sh push` (no sudo, hot reload) |
| `alloy.service.d/override.conf` | `/etc/systemd/system/alloy.service.d/override.conf` (`@USER@`/`@HOME@` filled in) | `install.sh` (sudo, one time) |
| `install.sh` | run from `/tmp/alloy-install.sh` | `deploy.sh stage`, then sudo |
| `deploy.sh` | runs here | `stage` / `push` / `check` |

## Design

- **One generic config.** `host` is `constants.hostname` and paths come from
  `$HOME`, so another desktop gets the same file unchanged.
- **Runs as the desktop user.** A PikaOS home is `0710`, so the package's
  `alloy` user can't read `~/.cache/kopia`. The drop-in sets `User=`, and config
  and state live in that home, so updates need no sudo. The UI and API listen on
  `127.0.0.1:12345` only.
- **Same Kopia labels as this host.** The `loki.process` stages were generated
  with `alloy convert --source-format=promtail` from the kopia job in
  `monitoring/promtail/promtail-config.yaml`. The `job`/`event`/`source`/`op`/
  `level`/`component` labels are therefore identical, and `/d/kopia` and the
  Kopia alerts just gain a `host` dimension. **When you change one pipeline,
  mirror it in the other.** To regenerate:
  ```bash
  sed -n '/^server:/,/^scrape_configs:/p;/job_name: kopia/,/job_name: la-events/p' \
    monitoring/promtail/promtail-config.yaml | head -n -1 > /tmp/p.yaml
  podman run --rm -v /tmp:/w:Z docker.io/grafana/alloy:v1.20.0 \
    convert --source-format=promtail -o /w/out.alloy /w/p.yaml
  ```
- **No backfill, no gaps.** `ignore_older_than = "24h"` skips log files untouched
  for a day, so a first install doesn't push months of old CLI logs (Loki keeps
  7 d anyway). New files are read from the start (`tail_from_end = false`).
  `tail_from_end = true` would also apply to every file created later (each CLI
  run, each server-log rotation) and drop its first lines.
- **Pinned** to `alloy=1.20.0-1` (apt-mark hold). To upgrade, bump
  `ALLOY_VERSION` in `install.sh` and re-run it.

## First install on a new desktop

1. On this host: add its static IP to `@pushers` in
   `monitoring/firewall/monitoring-lan.nft` and reinstall the firewall
   (`monitoring/firewall/README.md`).
2. `ALLOY_REMOTE_HOST=<ssh-host> monitoring/alloy/deploy.sh stage`
3. `ssh -t <ssh-host> 'sudo bash /tmp/alloy-install.sh $(whoami)'` (asks for its sudo password)
4. `ALLOY_REMOTE_HOST=<ssh-host> monitoring/alloy/deploy.sh check`
5. Add a per-host `kopia_backup_stale_*` rule (`log-alerts.yml`) and a row
   in `docs/HOSTS.md`.

## Day to day

```bash
monitoring/alloy/deploy.sh push    # after editing config.alloy (bad config = reload refused, old keeps running)
monitoring/alloy/deploy.sh check   # service, drift, component health, data arriving in Prometheus/Loki
ssh zuriel journalctl -u alloy -n 50 --no-pager
ssh -L 12345:127.0.0.1:12345 zuriel   # then http://127.0.0.1:12345 for Alloy's component graph
```
