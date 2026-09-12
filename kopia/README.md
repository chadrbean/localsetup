# kopia/ — desktop backup agent (native, not containerized)

**Native `.deb` install (KopiaUI) from the official Kopia apt repo, running
as `chad` under the desktop session — not a podman-compose stack.** Unlike
`litellm/`/`monitoring/`/`traefik/`, Kopia here is a GUI desktop app (system
tray icon, "Connect to Repository" wizard, autostart integration) rather
than a headless service, so it doesn't fit this repo's compose pattern.
This directory tracks its config/policies so the setup can be recreated
without relying on memory.

## What's running

- **KopiaUI 0.23.1**, installed via `apt` from `packages.kopia.io/apt stable
  main` (see Install below) — not a manual binary drop.
- Backs up three sources on this host (`wkspikaoschad`) to S3:
  - `/home/chad` — the only source with non-default policy: **hourly**
    scheduled snapshots + **gzip** compression (see
    `policies/home-chad.json`).
  - `/home/chad/.local/share/wave`
  - `/usr/local/bin`

  The latter two inherit the global policy as-is, so they have no policy
  file of their own here — only `/home/chad`'s override is tracked.
- Global retention policy (`policies/global.json`): 1 annual / 12 monthly /
  4 weekly / 7 daily / 48 hourly / 10 latest snapshots, ignores cache
  directories, honors `.kopiaignore`, zstd-fastest metadata compression.
- Kopia's own logs live at `~/.cache/kopia/cli-logs/*.log` on this host and
  are (or, depending on where `monitoring/`'s log-shipping work has landed,
  will be) tailed into Loki/Grafana for a "Kopia Backups" dashboard. That's
  monitoring of the agent; this directory is the agent's own config.

## What's tracked here (and what's deliberately not)

| File | Contents |
|---|---|
| `kopia-ui-autostart.desktop` | XDG autostart entry — installs into `~/.config/autostart/` |
| `policies/global.json` | `kopia policy export --global` output |
| `policies/home-chad.json` | `kopia policy export chad@wkspikaoschad:/home/chad` output |

**Not tracked, on purpose:** `~/.config/kopia/repository.config` itself.
It's a tool-generated file (not meant to be hand-edited or hand-copied
into place) and, on this host, its `storage.config` block holds the
**plaintext AWS access key + secret key** for the `chadrbean-backups`
bucket. Copying it into git — even "for reference" — would leak live
credentials. The repository connection details that *aren't* secret
(bucket, prefix, endpoint, cache sizing) are documented below instead, and
the repo is recreated with `kopia repository connect`, which regenerates
`repository.config` correctly.

You need the AWS access key/secret and the **repository password**
(encrypts the repo contents — separate from the AWS credentials) from
wherever you keep them (password manager / AWS IAM console). Kopia can't
recover the repository password if it's lost; it's only cached locally in
`repository.config.kopia-password`, never stored in git.

## Restore from scratch (new machine / reinstall)

```bash
# 1. install KopiaUI from the official apt repo
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://kopia.io/signing-key | sudo gpg --dearmor -o /etc/apt/keyrings/kopia-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main" \
  | sudo tee /etc/apt/sources.list.d/kopia.list
sudo apt update && sudo apt install kopia-ui

# 2. reconnect to the existing S3 repository (fill in the two secrets + password)
kopia repository connect s3 \
  --bucket=chadrbean-backups \
  --prefix=wkspikaoschad/ \
  --endpoint=s3.amazonaws.com \
  --access-key=<AWS_ACCESS_KEY_ID> \
  --secret-access-key=<AWS_SECRET_ACCESS_KEY> \
  --override-hostname=wkspikaoschad \
  --override-username=chad \
  --description=chadrbean-backup \
  --content-cache-size-mb=5000 \
  --metadata-cache-size-mb=5000 \
  -p <REPOSITORY_PASSWORD>

# 3. re-apply the tracked policies
kopia policy import --global --from-file kopia/policies/global.json
kopia policy import chad@wkspikaoschad:/home/chad --from-file kopia/policies/home-chad.json

# 4. re-add the snapshot sources (the other two use the global policy already applied above)
kopia snapshot create /home/chad
kopia snapshot create /home/chad/.local/share/wave
kopia snapshot create /usr/local/bin

# 5. install the autostart entry (see below) so KopiaUI launches without manual intervention
cp kopia/kopia-ui-autostart.desktop ~/.config/autostart/kopia-ui.desktop
```

## Autostart (the actual fix for "I have to open it the first time")

KopiaUI ships a desktop launcher (`/usr/share/applications/kopia-ui.desktop`)
but the `.deb` package does **not** install an XDG autostart entry — so it
only ever ran when launched by hand from the app menu. GNOME (and most
Linux desktops) auto-launches anything found in `~/.config/autostart/` at
login; that directory already had an entry for Bitwarden but none for
Kopia, which is exactly the gap.

Fix: `kopia-ui-autostart.desktop` here is a copy of the installed launcher
with `X-GNOME-Autostart-enabled=true` added, installed with:

```bash
cp kopia/kopia-ui-autostart.desktop ~/.config/autostart/kopia-ui.desktop
```

Takes effect on the next login/reboot. If Kopia is ever upgraded and the
packaged `.desktop` file changes (icon name, exec path), diff
`/usr/share/applications/kopia-ui.desktop` against this file and
re-sync both.

## Re-exporting policies after a change

If retention/scheduling/compression is changed in the KopiaUI settings
UI (or via `kopia policy set`), re-export so this directory stays the
source of truth:

```bash
kopia policy export --global --to-file kopia/policies/global.json
kopia policy export chad@wkspikaoschad:/home/chad --to-file kopia/policies/home-chad.json
```
