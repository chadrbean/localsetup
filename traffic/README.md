# traffic/ — Traffic (Caddy) reverse proxy for *.chadrbean.com

Replaces the old caddy/ (hermes-caddy) install: same Caddy + Route53 DNS-01
setup, run via docker compose (podman-compatible) in this subfolder.

- Wildcard TLS cert `*.chadrbean.com` (Let's Encrypt, DNS-01 via route53).
- Certs live in the shared named volume `caddy_data` — survives compose
  down; the old hermes-caddy container keeps working off the same volume.
- `hermes.chadrbean.com:18443` → hermes on `host.containers.internal:9119`
  (TLS arrives from sslh on 18443 — same as the old install).
- `me.chadrbean.com` is deliberately NOT routed — it's a generic DNS record
  kept at the home IP by `/usr/local/bin/awsChadHomeIp.sh`, no app behind it.
- Everything else under `*.chadrbean.com` → 404 placeholder. To add an app:
  1. add its site block to the Caddyfile (mirror the hermes block),
  2. point a DNS A record for it at this host (edit the zone / awsChadHomeIp),
  3. `podman compose -f compose.yaml restart`.

## Setup

    # 1. AWS keys for the route53 DNS-01 IAM user (hermes-caddy-dns01):
    cp .env.example .env          # fill in AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY

    # 2. Build the Caddy image (only needed once, or when the base version changes):
    podman compose -f compose.yaml build

    # 3. Start:
    podman compose -f compose.yaml up -d

    # Verify the wildcard cert was issued:
    podman compose -f compose.yaml logs traffic | grep -i "certificate"
    # or:
    ls ~/.local/share/containers/storage/volumes/caddy_data/_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/chadrbean.com/

## Ports / sslh

The host publishes 8443 via sslh (SSH/TLS split → 18443), so
`hermes.chadrbean.com:8443` works. Traffic binds 127.0.0.1:18443 only.
