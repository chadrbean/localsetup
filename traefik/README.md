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
- `otbla-local.chadrbean.com` → the blog's Hugo dev container (`[::1]:1313`) plus
  Decap CMS's `decap-server` (`127.0.0.1:8081`, router `otbla-local-cms`,
  `/api/v1`). Both routers are gated by HTTP basic auth (`otbla-local-auth`,
  hash in `.env` as `OTBLA_LOCAL_AUTH`, user `chad`). **Both routers must list
  the middleware**: the name is public (DNS + sslh), `decap-server` has no auth
  and writes the blog working copy, and `/admin/` serves the editor. Found open
  2026-09-26. Decap's `proxy` backend sends no `Authorization` header of its
  own, so the browser reuses the basic-auth login for `/api/v1` (same origin).
  `decap-server` itself must listen on loopback only (`BIND_HOST=127.0.0.1`,
  unit tracked at `../decap/decap-server.service`, see `../docs/HOSTS.md`),
  otherwise anything on the LAN can hit `:8081` and skip Traefik. fail2ban can't
  lock out anyone here (sslh → every client is `127.0.0.1`), so use a long random
  password. Verify after any change:
  `curl -sk -o /dev/null -w '%{http_code}\n' https://otbla-local.chadrbean.com/admin/`
  and the same for `/api/v1` → both `401`; `ss -tlnp | grep :8081` → `127.0.0.1` only.
- `accounting.chadrbean.com` → zca-accounting's local stack (web
  `127.0.0.1:3001`). **No proxy auth, and none is possible**: the app's
  browser-side pages send their own `Authorization: Bearer` header, which
  would replace a basic-auth header and turn every data fetch into a 401.
  The app's sign-in is the only gate, hardened for this address on the app
  side (email allowlist, secret check, per-account lockout, signup and
  tenant portal return 404). The `accounting` router is the on/off switch:
  comment it out plus `podman restart traefik` takes the app offline
  publicly. Full procedure: `zca-accounting/docs/runbooks/external-access.md`.
- Catch-all `HostRegexp` router → `noop@internal` (404) for every other
  subdomain.
- Loopback-only insecure API entrypoint (`traefik/traefik.yml`, entrypoint
  named `traefik` bound to `127.0.0.1:8083`, `api.insecure: true`). Added
  2026-09-19 so Homepage's `traefik` widget (`homepage/`, same box,
  `network_mode: host`) can read router/service/middleware counts with zero
  credentials. **Must stay named `traefik` and explicitly bound to
  `127.0.0.1`** — `api.insecure: true` with no matching entrypoint
  auto-creates one on `0.0.0.0:8080`, which would publicly leak the full
  routing table (same class of bug as the dashboard-auth pitfall above).
  Verify after any change: `ss -tlnp | grep :8083` → must show only
  `127.0.0.1:8083`, and a curl from outside the LAN must fail to connect.
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
    192.168.1.30 serpbear.chadrbean.com
    192.168.1.30 litellm.chadrbean.com
    192.168.1.30 me.chadrbean.com
    192.168.1.30 accounting.chadrbean.com

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

The same recipe rotates `ME_DASHBOARD_AUTH` (`me.chadrbean.com`) and
`OTBLA_LOCAL_AUTH` (`otbla-local.chadrbean.com`, Decap CMS): swap the variable name in
the `sed`/`printf` lines. Generate a password with `openssl rand -base64 24`
and keep it in a password manager or a `chmod 600` file, not in chat.

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
