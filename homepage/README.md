# homepage — landing page for all public admin interfaces

[Homepage](https://github.com/gethomepage/homepage) as a rootless
`podman-compose` stack, published at `https://me.chadrbean.com` through
Traefik. Run `podman-compose <args>` from this directory; there is no `.env`
(no secrets — config is static YAML, no widget API keys; the Traefik widget
below reads Traefik's loopback-only insecure API, no credentials needed).

## Components

| Piece | Detail |
|---|---|
| Image | `ghcr.io/gethomepage/homepage:v2.4.0` (pinned; check releases before bumping) |
| Network | `network_mode: host` (like traefik/monitoring), `HOSTNAME=127.0.0.1` forces the listener to stay loopback-only — verify with `ss -tlnp \| grep :3005` after any compose change, must show `127.0.0.1:3005`, never `0.0.0.0`/`*` |
| User | `PUID=1000`/`PGID=1000` — server process runs as `node` (host uid `chad`), never root; verify `podman top homepage user pid comm` |
| Config/data | bind mount `~/.local/share/homepage/config` → `/app/config` (services.yaml, settings.yaml, bookmarks.yaml, widgets.yaml) |
| Auth | Homepage has **no login of its own** — the Traefik `me-dashboard-auth` basic-auth middleware IS the auth gate (separate credentials from `traefik.chadrbean.com`'s `dashboard-auth`) |
| Edge | `traefik/dynamic.yml` router/service `me` (wildcard cert, `fail2ban` middleware) |
| DNS | Route53 A `me.chadrbean.com` (terraform `modules/dns`), IP kept current by `scripts/awsChadHomeIp.sh` (was already present before this stack existed) |

**Why `network_mode: host`, not the default bridge**: Homepage's
`siteMonitor`/widget HTTP checks run from inside the container. In bridge
mode, `127.0.0.1` inside the container is only the container itself, so
loopback-port checks against Hermes/Grafana/etc. failed
(`ECONNREFUSED`)  and hairpin hostnames like `otbla.chadrbean.com` also
failed to resolve/connect from the container's own bridge network. Host
networking lets `siteMonitor: http://127.0.0.1:<port>/` reach the real host
service directly, same as every other stack in this repo.

## Files

    homepage/
      docker-compose.yml   stack definition

    ~/.local/share/homepage/config/
      settings.yaml   title, theme, layout, quicklaunch
      services.yaml   the cards — one entry per admin app (siteMonitor +
                       optional widget block, e.g. the Traefik card's
                       router/service/middleware counts)
      bookmarks.yaml  AWS console shortcuts (Route53, EC2, SES)
      widgets.yaml    header info bar: system resources (CPU/mem/disk),
                       clock, Open-Meteo weather (Burbank, CA — no API key),
                       quick search (DuckDuckGo)

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
            siteMonitor: http://127.0.0.1:<backend-port>/   # loopback, NOT the public URL — see network_mode note above
            description: <one line>

Then: `podman-compose restart homepage` (no rebuild needed — Homepage
hot-reloads its config directory).

## Traefik router/service/middleware counts widget

The Traefik card's `widget:` block reads `http://127.0.0.1:8080` — a new
loopback-only `traefik` entrypoint (`traefik/traefik.yml`, `api.insecure:
true`) added specifically for this. It's **never** routed through the
public `websecure` entrypoint and isn't reachable off-box; confirmed with
`ss -tlnp | grep :8080` (must show `127.0.0.1:8080` only) and a curl from
outside the LAN.

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
