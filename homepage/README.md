# homepage — landing page for all public admin interfaces

[Homepage](https://github.com/gethomepage/homepage) as a rootless
`podman-compose` stack, published at `https://me.chadrbean.com` through
Traefik. Run `podman-compose <args>` from this directory; there is no `.env`
in the MVP (no secrets — config is static YAML, no widget API keys).

## Components

| Piece | Detail |
|---|---|
| Image | `ghcr.io/gethomepage/homepage:v2.4.0` (pinned; check releases before bumping) |
| Port | `127.0.0.1:3005` → container `3005` (loopback only) |
| Config/data | bind mount `~/.local/share/homepage/config` → `/app/config` (services.yaml, settings.yaml, bookmarks.yaml, widgets.yaml) |
| Auth | Homepage has **no login of its own** — the Traefik `me-dashboard-auth` basic-auth middleware IS the auth gate (separate credentials from `traefik.chadrbean.com`'s `dashboard-auth`) |
| Edge | `traefik/dynamic.yml` router/service `me` (wildcard cert, `fail2ban` middleware) |
| DNS | Route53 A `me.chadrbean.com` (terraform `modules/dns`), IP kept current by `scripts/awsChadHomeIp.sh` (was already present before this stack existed) |

## Files

    homepage/
      docker-compose.yml   stack definition

    ~/.local/share/homepage/config/
      settings.yaml   title, theme, layout
      services.yaml   the cards — one entry per admin app
      bookmarks.yaml  empty ([]) — unused
      widgets.yaml    empty ([]) — header widgets, unused (Phase 2)

## First run

    cd homepage
    mkdir -p ~/.local/share/homepage/config
    # write settings.yaml / services.yaml / bookmarks.yaml / widgets.yaml
    podman-compose up -d
    curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3005/

## Adding a new admin app to the landing page

Homepage does **not** auto-discover — there's no podman.sock mount here
deliberately (that socket is root-equivalent host access). Whenever a new
router is added to `traefik/dynamic.yml`, also add a matching card to
`~/.local/share/homepage/config/services.yaml`:

    - <Group>:
        - <Name>:
            icon: si-<slug>            # https://gethomepage.dev icons; drop if it 404s
            href: https://<app>.chadrbean.com/
            siteMonitor: https://<app>.chadrbean.com/   # PUBLIC url, not loopback
            description: <one line>

Then: `podman-compose restart homepage` (no rebuild needed — Homepage
hot-reloads its config directory).

## Basic auth credentials

Separate htpasswd hash from the Traefik dashboard's, stored as
`ME_DASHBOARD_AUTH` in `traefik/.env` (see `traefik/README.md` "Dashboard"
section for the exact `htpasswd -nbB` recipe — same single-`$`,
do-not-double-escape rule applies here).

## Persistence / backup

Everything stateful is under `~/.local/share/homepage/config/` —
`podman-compose down` and image rebuilds keep it. Back up that directory
(Kopia already covers `~/.local/share` if configured).

## Adding/changing the hostname

`me.chadrbean.com` was already a DNS-only Route53 record and already in
`scripts/awsChadHomeIp.sh` `DNS_RECORDS` before this stack existed — no DNS
change was needed to add the Traefik route. For a brand-new hostname, see
the "new app" checklist in the root `CLAUDE.md`.
