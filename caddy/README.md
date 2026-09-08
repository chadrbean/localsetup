# caddy/ — ARCHIVED (not running)

Previous edge proxy (Caddy 2 + caddy-dns/route53, quadlet `hermes-caddy`).
Superseded by `../traefik/` on 2026-09-07. Kept for reference in case we
switch back; the quadlet, containers, images, and caddy_data/caddy_config
volumes (incl. the Caddy-issued certs) were destroyed. `.env` here still
holds the route53 IAM keys (hermes-caddy-dns01), shared with `../traefik/.env`.
