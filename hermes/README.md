# hermes/ — reference copies for the Hermes agent

Hermes itself is installed under `~/.hermes` (not in this repo). This directory
tracks the pieces worth recreating by hand:

| File | Live location |
|---|---|
| `config.yaml` | `~/.hermes/config.yaml` (reference only; secrets stay blank here) |
| `systemd/hermes-watchdog.sh` + `.service` | `~/.config/systemd/user/` |

## Watchdog

`hermes-watchdog.service` checks every 60 s. It starts `hermes-dashboard.service`
if it's inactive, and restarts it if it's active but nothing listens on `:9119`,
though **not during the first 10 minutes after the unit starts** (`STARTUP_GRACE_SEC`).
A dashboard start may first finish an interrupted source update: it rebuilds the TUI,
the web UI and the desktop app, which takes several minutes. Without the grace period the
watchdog killed that build every minute, starting 2026-09-25. That left ~1,400
`apps/desktop/.dist-build-*` dirs (~65 GB), which Kopia also uploaded.

Install / update:

```bash
cp hermes/systemd/hermes-watchdog.sh hermes/systemd/hermes-watchdog.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user restart hermes-watchdog.service
journalctl --user -t hermes-watchdog -f
```
