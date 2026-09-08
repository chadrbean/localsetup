# traefik/ — Traefik edge proxy for *.chadrbean.com

Replaces the archived `../caddy/` setup. Traefik v3 official image (Route53
DNS-01 built in via lego — no custom Containerfile needed), run with podman
compose, `network_mode: host`.

- Wildcard TLS cert `*.chadrbean.com` (Let's Encrypt, DNS-01 via route53,
  pinned to the public zone with `AWS_HOSTED_ZONE_ID`). Cert + ACME account
  live in the named volume `traefik_data` (`/data/acme.json`).
- `hermes.chadrbean.com` → hermes dashboard `127.0.0.1:9119` (host network).
- Catch-all `HostRegexp` router → `noop@internal` (404) for every other
  subdomain. `me.chadrbean.com` is a DNS-only record (kept fresh by
  `/usr/local/bin/awsChadHomeIp.sh`), not routed.
- Public access: sslh on `:8443` splits SSH→22 / TLS→`127.0.0.1:18443`.

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
