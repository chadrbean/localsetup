# traefik/ — Traefik edge proxy for *.chadrbean.com

Replaces the archived `../caddy/` setup. Traefik v3 official image (Route53
DNS-01 built in via lego — no custom Containerfile needed), run with podman
compose, `network_mode: host`.

- Wildcard TLS cert `*.chadrbean.com` (Let's Encrypt, DNS-01 via route53,
  pinned to the public zone with `AWS_HOSTED_ZONE_ID`). Cert + ACME account
  live in the named volume `traefik_data` (`/data/acme.json`).
- `hermes.chadrbean.com` → hermes dashboard `127.0.0.1:9119` (host network).
- `traefik.chadrbean.com` → Traefik's own dashboard (`api@internal`),
  gated by HTTP basic auth (`dashboard-auth` middleware). Credentials in
  `.env` (`TRAEFIK_DASHBOARD_AUTH`, a bcrypt hash — see "Dashboard" below).
  **This middleware must be listed on the `dashboard` router in
  `dynamic.yml`** — defining `dashboard-auth` under `middlewares:` does
  nothing on its own. Found on 2026-09-12 that the router had only
  `[fail2ban]` and the dashboard + `/api/*` (full routing table, backend
  addresses) were serving publicly with no auth at all; fail2ban doesn't
  catch this either since a bare dashboard `200` never trips its
  400/401/403-499 ban trigger. Verify after any change:
  `curl -sk -o /dev/null -w '%{http_code}\n' https://traefik.chadrbean.com/dashboard/`
  → must be `401`, not `200`.
- `fail2ban` middleware (Traefik plugin `github.com/tomMoulard/fail2ban`
  v0.9.0) on every HTTP router: bans an IP for 3h after 5 requests hitting
  400/401/403-499 within a 10-minute window. **HTTP-only** — protects the
  dashboard/hermes/catch-all surface, NOT SSH (sslh forwards SSH straight
  to sshd, bypassing Traefik entirely; see `../fail2ban/` for that).
- Catch-all `HostRegexp` router → `noop@internal` (404) for every other
  subdomain. `me.chadrbean.com` is a DNS-only record (kept fresh by
  `/usr/local/bin/awsChadHomeIp.sh`), not routed.
- Public access: sslh on `:443` splits SSH→22 / TLS→`127.0.0.1:18443`.
  As of 2026-09-12, plain `https://hermes.chadrbean.com/` (no port) works —
  moved off `:8443` back onto `:443`. **History:** AT&T fiber was found
  blocking inbound 443 on 2026-09-07 (port-forwarding 443→8443 on the
  router didn't help; the ISP gateway refused the connection before it
  reached us), so the stack ran on `:8443` for 5 days. On 2026-09-12 it was
  switched back to `:443` at the user's request without re-confirming the
  AT&T block is actually gone — **if `https://*.chadrbean.com/` (no port)
  stops resolving from outside the LAN, that block is probably still
  there.** Rollback: `/etc/default/sslh.bak-8443` has the prior working
  config — `sudo cp /etc/default/sslh.bak-8443 /etc/default/sslh &&
  sudo systemctl restart sslh`, revert the router's port-forward back to
  443→8443, and revert `GF_SERVER_ROOT_URL` in
  `monitoring/docker-compose.yml` to include `:8443`.
  sslh's actual listen/target ports live in `/etc/default/sslh`
  (`DAEMON_OPTS`), NOT in this directory — it's a system service, not a
  container. Must read `--listen 0.0.0.0:443 --ssh 127.0.0.1:22 --tls
  127.0.0.1:18443`; the Debian package ships a placeholder
  `<change-me>:443` that silently crash-loops the service if never edited.
  Managed with `systemctl {enable,start,status} sslh` — check
  `journalctl -u sslh` if `:443` isn't listening (`ss -tlnp | grep :443`).

### Local access from this host (hairpin NAT)

This box can't reach its own public IP through the router (no hairpin
NAT support), so resolving `*.chadrbean.com` normally on the Traefik host
itself times out even though it works fine from LAN and the public
internet. Fixed with `/etc/hosts` entries pointing every routed name at
this host's own LAN IP instead:

    192.168.1.30 hermes.chadrbean.com
    192.168.1.30 traefik.chadrbean.com
    192.168.1.30 otbla.chadrbean.com
    192.168.1.30 otbla-local.chadrbean.com
    192.168.1.30 grafana.chadrbean.com

Keep this list in sync with the `Host()` rules in `dynamic.yml` — the
`HostRegexp` catch-all has no wildcard equivalent in `/etc/hosts`, so a
newly added subdomain needs its own line here to resolve locally (it'll
still work fine from every other device without any change).

## Dashboard

`https://traefik.chadrbean.com/dashboard/` (basic auth, user `chad`).

The password hash lives in `.env` as `TRAEFIK_DASHBOARD_AUTH` — a plain
bcrypt hash (`htpasswd -nbB chad '<password>'`), **single `$`, NOT escaped**.
`dynamic.yml` picks it up via Traefik's Go-template file provider:
`{{ env `TRAEFIK_DASHBOARD_AUTH` }}` inside the `basicAuth` middleware —
the hash never appears in a tracked file, only in the git-ignored `.env`.

**Do not `$` → `$$` escape this value.** An earlier version of this doc
claimed podman-compose interpolates `${VAR}` inside `env_file` contents and
mangles the hash otherwise — that's false. Traced in podman-compose's own
source (`podman_compose.py`, the `env_file:` handling around
`dotenv_to_dict()`): `env_file` values are read via python-dotenv and passed
straight through as literal `-e KEY=VALUE` to `podman run`, with zero `$`
interpolation. `${VAR}` substitution only ever applies to the compose YAML
text itself, never to a file it references. Doubling the `$` corrupts the
hash (`$2y$05$...` needs single-`$` delimiters) so basic auth silently
never accepts *any* password — found and fixed 2026-09-12 (confirmed via
`podman exec traefik printenv TRAEFIK_DASHBOARD_AUTH`, which showed the
literal `$$` making it into the container's environment unchanged).

To change the password:

    NEWPW='...'  # pick one, don't paste it in chat/logs
    HASH=$(htpasswd -nbB chad "$NEWPW")
    sed -i '/^TRAEFIK_DASHBOARD_AUTH=/d' .env
    printf 'TRAEFIK_DASHBOARD_AUTH=%s\n' "$HASH" >> .env
    podman-compose -f docker-compose.yaml up -d --force-recreate   # env_file
        # is baked in at container CREATION — a plain `restart` won't pick
        # up a changed .env, only up -d --force-recreate will.
    # verify: printenv TRAEFIK_DASHBOARD_AUTH inside the container should
    # show single $ (chad:$2y$05$...), and /dashboard/ with no credentials
    # must return 401.

## Add an app

1. Add an A record for `<app>.chadrbean.com` → this host's IP (or extend
   awsChadHomeIp.sh).
2. Add a router + service block to `dynamic.yml` — copy the `hermes` pair.
   **Set `priority:` > 1** (default priority = rule length; the catch-all
   HostRegexp rule is longer than any Host() rule and would win otherwise).
   Reuse the same `tls:` block — the wildcard cert is shared, no new cert.
3. Watch logs: `podman logs -f traefik` (file provider hot-reloads
   `dynamic.yml`).

## Setup from scratch

    cp .env.example .env      # fill AWS keys (IAM user hermes-caddy-dns01)
    podman-compose -f docker-compose.yaml up -d
    podman logs -f traefik    # watch for the ACME cert being obtained

## Boot persistence

`restart: unless-stopped` + `systemctl --user enable --now podman-restart.service`
brings Traefik back after reboot (no quadlet needed).

## Verify

    # direct (traefik on loopback 18443):
    curl -s -o /dev/null -w '%{http_code}\n' --resolve hermes.chadrbean.com:18443:127.0.0.1 https://hermes.chadrbean.com:18443/
    # → 302 (hermes redirects to /login)
    # catch-all:
    curl -s --resolve foo.chadrbean.com:18443:127.0.0.1 https://foo.chadrbean.com:18443/ -w ' [%{http_code}]\n'
    # → 404
    # through sslh (public path):
    curl -s -o /dev/null -w '%{http_code}\n' --resolve hermes.chadrbean.com:443:127.0.0.1 https://hermes.chadrbean.com/
    # → 302
