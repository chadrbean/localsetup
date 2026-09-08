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
- Catch-all `HostRegexp` router → `noop@internal` (404) for every other
  subdomain. `me.chadrbean.com` is a DNS-only record (kept fresh by
  `/usr/local/bin/awsChadHomeIp.sh`), not routed.
- Public access: sslh on `:8443` splits SSH→22 / TLS→`127.0.0.1:18443`.
  **Always use `:8443` in URLs** (e.g. `https://hermes.chadrbean.com:8443/`)
  — AT&T fiber blocks inbound port 443 on residential gateways (reserved
  for their own DVR/receiver provisioning), confirmed 2026-09-07: port
  forwarding 443→8443 on the router does not help, the ISP gateway itself
  refuses the connection before it reaches us. Only 8443 is forwarded.

## Dashboard

`https://traefik.chadrbean.com:8443/dashboard/` (basic auth, user `chad`).
Note the `:8443` — see the AT&T port-443-block note above.

The password hash lives in `.env` as `TRAEFIK_DASHBOARD_AUTH` — a bcrypt
hash (`htpasswd -nbB chad '<password>'`), **double-dollar escaped**
(`$` → `$$`) because podman-compose applies `$VAR` interpolation to
`env_file` values, which otherwise mangles the hash's `$2y$05$...` syntax.
`dynamic.yml` picks it up via Traefik's Go-template file provider:
`{{ env `TRAEFIK_DASHBOARD_AUTH` }}` inside the `basicAuth` middleware —
the hash never appears in a tracked file, only in the git-ignored `.env`.

To change the password:

    NEWPW='...'  # pick one, don't paste it in chat/logs
    HASH=$(htpasswd -nbB chad "$NEWPW")
    ESCAPED=$(echo "$HASH" | sed 's/\$/\$\$/g')
    sed -i '/^TRAEFIK_DASHBOARD_AUTH=/d' .env
    printf 'TRAEFIK_DASHBOARD_AUTH=%s\n' "$ESCAPED" >> .env
    podman compose -f compose.yaml up -d   # recreate to pick up the new env

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
    podman compose up -d
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
    curl -s -o /dev/null -w '%{http_code}\n' --resolve hermes.chadrbean.com:8443:127.0.0.1 https://hermes.chadrbean.com:8443/
    # → 302
