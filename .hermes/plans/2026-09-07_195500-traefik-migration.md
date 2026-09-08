# Plan: Migrate edge proxy Caddy → Traefik (repo `~/git/localsetup`)

**Date:** 2026-09-07 (PDT) · **Target repo:** `/home/chad/git/localsetup` (branch `main`, remote `[EMAIL]:chadrbean/localsetup.git`)

## Goal

Replace the running Caddy edge proxy with Traefik (Route53 DNS-01, wildcard cert `*.chadrbean.com`) in a compose install under `traefik/`, keep the Caddy configuration archived in-repo (NOT live), and destroy all running Caddy containers/volumes/images/services.

## Current context / assumptions

Live state (verified 2026-09-07, re-verify with Task 0):

| Item | State |
|---|---|
| `~/git/localsetup/traffic/` | Caddy compose install (Caddyfile, compose.yaml, Containerfile, .env, .env.example, .gitignore, README.md) — committed at `b51daf1` |
| `~/git/localsetup/caddy/` | Original quadlet-era Caddy config (Caddyfile, Containerfile, `.env` with AWS keys) — committed, this is the archive to KEEP |
| Container `traffic-caddy` | RUNNING, image `localhost/traffic-caddy:latest`, publishes `127.0.0.1:18443` via pasta, on user-defined podman network `traffic`, volumes `caddy_data` + `caddy_config` |
| Quadlet `~/.config/containers/systemd/hermes-caddy.container` | exists, unit `hermes-caddy.service` stopped + disabled |
| Image `localhost/hermes-caddy:latest` | exists (same image ID as traffic-caddy) |
| `sslh` user unit (`~/.config/systemd/user/sslh.service`) | ACTIVE. Public `0.0.0.0:8443` → SSH `127.0.0.1:22`, TLS `127.0.0.1:18443`. Has stale `After=hermes-caddy.service` line. Config `~/.config/sslh/sslh.conf` |
| Hermes dashboard | host process, listens `0.0.0.0:9119` |
| Wildcard cert `*.chadrbean.com` | already issued by Caddy (LE prod) into `caddy_data` volume — will be DESTROYED; Traefik issues a fresh one (LE limit: 5 duplicate certs/week — only 1 used so far, safe) |
| DNS | Route53 public zone `chadrbean.com` = `Z030496415CSA0E3T50AY`. A records: `me.chadrbean.com` (kept, maintained hourly by `/usr/local/bin/awsChadHomeIp.sh`), `hermes.chadrbean.com` → home IP (added this session). NOTE: a PRIVATE zone `chadrbean.com` also exists — the ACME resolver must be pinned to the public zone ID |
| AWS IAM | user `hermes-caddy-dns01` (keys in `caddy/.env`, copied to `traffic/.env`). Inline policy allows `route53:ChangeResourceRecordSets`+`ListResourceRecordSets` on zone `Z030496415CSA0E3T50AY`, `route53:GetChange`, `route53:ListHostedZonesByName` — sufficient for Traefik/lego with `AWS_HOSTED_ZONE_ID` set |

Routing to preserve (user-confirmed):
- `hermes.chadrbean.com` → hermes dashboard `:9119`
- every other `*.chadrbean.com` → 404 placeholder
- `me.chadrbean.com` → NOT routed (DNS record only)
- TLS arrives from sslh on `127.0.0.1:18443`; public port stays `8443`

Assumptions:
- podman + podman-compose (podman's compose provider), rootless, user `chad`, linger enabled.
- Traefik official image `traefik:v3` includes the lego Route53 DNS-01 provider — NO custom Containerfile needed (unlike Caddy).
- `network_mode: host` under rootless podman joins the host netns → Traefik binds `127.0.0.1:18443` directly (no pasta) and reaches hermes at `127.0.0.1:9119` (avoids the LAN-IP hack Caddy needed).
- **Secrets rule:** never `cat`/print `.env`. Only check key NAMES (`grep -oE '^[A-Z_]+='`).

## Architecture

Traefik v3 runs from a compose file in `traefik/` with `network_mode: host`, static config `traefik.yml` (entrypoint `websecure` on `127.0.0.1:18443`, ACME resolver `route53` via DNS-01 with `AWS_HOSTED_ZONE_ID` pinned, storage in named volume `traefik_data`), and file-provider dynamic config `dynamic.yml` (router `hermes` → `http://127.0.0.1:9119` with explicit priority, catch-all `HostRegexp` router → `noop@internal` = 404). Both routers declare the same wildcard `tls.domains`, so ONE cert `*.chadrbean.com` is issued and shared. `caddy/` stays in the repo as an archived, non-running configuration; all Caddy runtime state (containers, volumes, images, quadlet) is destroyed.

---

## Step-by-step tasks

### Task 0 — Pre-flight verification (read-only, ~2 min)

```bash
podman ps --format '{{.Names}} {{.Status}}'          # expect: traffic-caddy Up ...
ss -tlnp | grep 18443                                 # expect: 127.0.0.1:18443 rootlessport
systemctl --user is-active sslh                       # expect: active
ls ~/git/localsetup/caddy/.env ~/git/localsetup/traffic/.env   # both exist
grep -oE '^[A-Z_]+=' ~/git/localsetup/traffic/.env    # expect: AWS_ACCESS_KEY_ID= AWS_SECRET_ACCESS_KEY= AWS_REGION=
git -C ~/git/localsetup status -sb                    # expect: ## main...origin/main (clean)
```

If the working tree is dirty, `git -C ~/git/localsetup stash list` and ask the user before proceeding.

### Task 1 — Rename folder: `traffic/` → `traefik/`, drop Caddy files (~3 min)

```bash
cd ~/git/localsetup
git mv traffic traefik
git rm traefik/Caddyfile traefik/Containerfile
```

Verify: `ls traefik/` shows only `compose.yaml  .env  .env.example  .gitignore  README.md` (compose.yaml/README.md get replaced in Task 2).

### Task 2 — Write the Traefik configuration files (~10 min)

**File `~/git/localsetup/traefik/traefik.yml`** (static config) — write exactly:

```yaml
# Traefik v3 static config — localsetup edge proxy for *.chadrbean.com
# TLS via Let's Encrypt DNS-01 (Route53). Runs with network_mode: host,
# so websecure binds 127.0.0.1:18443 directly (sslh forwards 8443 -> 18443).

entryPoints:
  websecure:
    address: "127.0.0.1:18443"

providers:
  file:
    filename: /etc/traefik/dynamic.yml
    watch: true

certificatesResolvers:
  route53:
    acme:
      storage: /data/acme.json
      dnsChallenge:
        provider: route53
        delayBeforeCheck: 15
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"

log:
  level: INFO
```

**File `~/git/localsetup/traefik/dynamic.yml`** — write exactly:

```yaml
# Traefik dynamic config (file provider). One app = one router block.
# PITFALL: priorities are explicit because Traefik defaults priority to
# rule LENGTH, and the HostRegexp catch-all is longer than Host(`hermes...`).
# New app routers MUST set a priority above 1.
# The wildcard cert is issued once (first router's tls.domains) and shared.

routers:
  hermes:
    rule: Host(`hermes.chadrbean.com`)
    entryPoints: [websecure]
    service: hermes
    priority: 100
    tls:
      certResolver: route53
      domains:
        - main: "*.chadrbean.com"

  catchall:
    rule: HostRegexp(`.+\.chadrbean\.com`)
    entryPoints: [websecure]
    service: noop@internal
    priority: 1
    tls:
      certResolver: route53
      domains:
        - main: "*.chadrbean.com"

services:
  hermes:
    loadBalancer:
      servers:
        - url: "http://127.0.0.1:9119"
```

**File `~/git/localsetup/traefik/compose.yaml`** — overwrite with exactly:

```yaml
services:
  traefik:
    image: docker.io/library/traefik:v3
    container_name: traefik
    restart: unless-stopped
    # Rootless podman host netns: binds 127.0.0.1:18443 (sslh target) and
    # reaches host services on 127.0.0.1 (hermes :9119). No ports: section.
    network_mode: host
    volumes:
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic.yml:/etc/traefik/dynamic.yml:ro
      - traefik_data:/data
    env_file:
      - .env

volumes:
  traefik_data:
    name: traefik_data
```

**File `~/git/localsetup/traefik/.env.example`** — overwrite with exactly:

```
# Copy to .env and fill in real values. .env is git-ignored — never commit it.
# IAM user hermes-caddy-dns01 (route53 DNS-01 for chadrbean.com [REDACTED] (same key files as caddy/.env).
AWS_ACCESS_KEY_ID=
AWS_SECRET…KEY=
AWS_REGION=us-west-1
# Pin lego to the PUBLIC zone (a private chadrbean.com zone also exists):
AWS_HOSTED_ZONE_ID=Z030496415CSA0E3T50AY
```

**`~/git/localsetup/traefik/.env`** (git-ignored) — build from the working keys + add the zone pin. Do NOT print values:

```bash
cd ~/git/localsetup/traefik
cp ../caddy/.env .env && chmod 600 .env
echo 'AWS_HOSTED_ZONE_ID=Z030496415CSA0E3T50AY' >> .env
grep -oE '^[A-Z_]+=' .env   # expect 4 lines: AWS_ACCESS_KEY_ID= AWS_SECRET_ACCESS_KEY= AWS_REGION= AWS_HOSTED_ZONE_ID=
```

(`traffic/.env` already equals `caddy/.env`; copying from `caddy/.env` is equivalent and survives if `traefik/.env` got clobbered by the overwrite above.)

**File `~/git/localsetup/traefik/.gitignore`** — keep as-is (`.env`).

**File `~/git/localsetup/traefik/README.md`** — overwrite with exactly:

```markdown
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
3. `podman exec traefik traefik healthcheck` is not enabled; just watch logs:
   `podman logs -f traefik` (file provider hot-reloads `dynamic.yml`).

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
```

**File `~/git/localsetup/caddy/README.md`** — create (archive note):

```markdown
# caddy/ — ARCHIVED (not running)

Previous edge proxy (Caddy 2 + caddy-dns/route53, quadlet `hermes-caddy`).
Superseded by `../traefik/` on 2026-09-07. Kept for reference in case we
switch back; the quadlet, containers, images, and caddy_data/caddy_config
volumes (incl. the Caddy-issued certs) were destroyed. `.env` here still
holds the route53 IAM keys (hermes-caddy-dns01), shared with `../traefik/.env`.
```

Validate compose syntax:

```bash
cd ~/git/localsetup/traefik && podman compose -f compose.yaml config --quiet && echo COMPOSE-OK
```
Expected: `COMPOSE-OK` (ignore the "external compose provider" notice).

Commit:

```bash
cd ~/git/localsetup && git add -A && git commit -m "feat(traefik): Traefik v3 compose edge proxy (host net, route53 DNS-01 wildcard); traffic/ renamed, caddy/ archived"
```

### Task 3 — Stop & destroy the Caddy runtime (~3 min)

```bash
podman stop traffic-caddy && podman rm traffic-caddy
podman network rm traffic
rm ~/.config/containers/systemd/hermes-caddy.container
systemctl --user daemon-reload
```

Verify:

```bash
ss -tlnp | grep 18443        # expect: NO output (port free — pasta gone)
podman ps -a | grep -i caddy # expect: NO output
systemctl --user status hermes-caddy.service 2>&1 | head -1   # expect: "Unit hermes-caddy.service could not be found."
```

### Task 4 — Start Traefik and watch the wildcard cert issue (~5 min)

```bash
cd ~/git/localsetup/traefik
podman compose -f compose.yaml up -d
podman logs -f traefik   # Ctrl-C when you see the cert lines below
```

Expected in logs (within ~60s):
- `level=info msg="Starting provider..."` / no config errors
- lego/ACME lines: `Trying to solve DNS-01 challenge` / `acme: Preparing to solve DNS-01`
- `Certificates obtained successfully` or the router serving without ACME errors

Verify cert stored + served:

```bash
podman exec traefik sh -c "grep -c 'chadrbean.com' /data/acme.json"   # expect: >= 1
curl -sv --max-time 15 --resolve hermes.chadrbean.com:18443:127.0.0.1 https://hermes.chadrbean.com:18443/ -o /dev/null 2>&1 | grep -E 'subject:|issuer:'
```
Expected: `subject: CN=*.chadrbean.com` and `issuer: ... Let's Encrypt` **without** `(STAGING)`.

If DNS-01 fails with NXDOMAIN: check `podman logs traefik | grep -i acme`, confirm `AWS_HOSTED_ZONE_ID` is in the container env (`podman exec traefik env | grep -c AWS_HOSTED_ZONE_ID` → 1), and that no stale `_acme-challenge` TXT lingers:
`aws route53 list-resource-record-sets --hosted-zone-id Z030496415CSA0E3T50AY --query 'ResourceRecordSets[?contains(Name,`_acme-challenge`)]' --output text` → empty.

### Task 5 — End-to-end validation through sslh (~2 min)

```bash
curl -s -o /dev/null -w '%{http_code}\n' --resolve hermes.chadrbean.com:8443:127.0.0.1 https://hermes.chadrbean.com:8443/
# expect: 302
curl -s --resolve foo.chadrbean.com:8443:127.0.0.1 https://foo.chadrbean.com:8443/ -w ' [%{http_code}]\n'
# expect: 404 (body "404 page not found")
```

Both must pass before Task 6 (destroying volumes is irreversible).

### Task 6 — Destroy Caddy volumes + images (~2 min)

```bash
podman volume rm caddy_data caddy_config
podman rmi localhost/traffic-caddy:latest localhost/hermes-caddy:latest
```

Verify:

```bash
podman volume ls | grep -i caddy   # expect: NO output
podman images | grep -iE 'caddy'   # expect: NO output
```

Note: this destroys the Caddy-issued certs (`chadrbean.com` apex, `me.chadrbean.com`, `*.chadrbean.com`). All re-issuable via LE if ever needed.

### Task 7 — Clean up stale references + boot persistence (~4 min)

1. `~/.config/systemd/user/sslh.service`: delete the two lines
   ```
   # Caddy must be off public 8443 before sslh binds it
   After=hermes-caddy.service
   ```
   and change `Description=SSL/SSH multiplexer for public port 8443 (SSH->22, TLS->18443 Caddy)` → `... TLS->18443 Traefik)`.
2. `~/.config/sslh/sslh.conf`: change the comment `TLS (HTTPS)   -> Caddy on 127.0.0.1:18443  (me.chadrbean.com)` → `TLS (HTTPS)   -> Traefik on 127.0.0.1:18443  (*.chadrbean.com)`. (Comment only — no behavior change.)
3. Apply + enable boot persistence:
   ```bash
   systemctl --user daemon-reload
   systemctl --user restart sslh.service        # brief 8443 blip; user is on LAN SSH :22 — safe
   systemctl --user is-active sslh              # expect: active
   systemctl --user enable --now podman-restart.service
   systemctl --user is-enabled podman-restart   # expect: enabled
   ```
4. Re-verify Task 5's two curls still pass (sslh restarted).

### Task 8 — Repo docs + final commit/push (~3 min)

1. In `~/git/localsetup/README.md`, under a new top-level section (append near the end, before/after `## Documentation` as fits):

```markdown
## Edge proxy (traefik/)

`traefik/` runs the public TLS edge for `*.chadrbean.com` (Traefik v3,
Route53 DNS-01 wildcard cert, podman compose, sslh :8443 → :18443).
`caddy/` is the archived predecessor — kept, not running. See
[traefik/README.md](traefik/README.md).
```

2. Commit + push:
```bash
cd ~/git/localsetup && git add -A && git commit -m "chore: destroy caddy runtime (containers/volumes/images/quadlet), sslh refs -> traefik, boot persistence via podman-restart; docs" && git push origin main
```
Expected: push succeeds (`main -> main`).

### Task 9 — Final state checklist (~1 min)

```bash
podman ps --format '{{.Names}} {{.Status}}' | grep traefik   # traefik Up
podman ps -a | grep -ci caddy                                 # 0
podman volume ls | grep -cE 'traefik_data'                    # 1
podman volume ls | grep -ci caddy                             # 0
git -C ~/git/localsetup status -sb                            # ## main...origin/main (clean)
ls ~/git/localsetup                                           # caddy  docs  hermes  litellm  scripts  systemd  traefik  PLAN.md README.md ...
```

---

## Tests / validation

No unit-testable code (infra). Each task embeds its verification command + expected output; the validation chain is:

1. **Config valid before run:** `podman compose config --quiet` → silent success (Task 2).
2. **Cert issued:** `acme.json` contains the domain; curl `-v` shows `subject: CN=*.chadrbean.com`, prod LE issuer (Task 4).
3. **Routing correct:** hermes → 302, unknown subdomain → 404, both direct :18443 and public-path :8443 through sslh (Tasks 4–5, re-run after Task 7's sslh restart).
4. **Caddy fully gone:** zero caddy containers/volumes/images/units (Tasks 3, 6, 9).
5. **Survives reboot:** `podman-restart.service` enabled + `restart: unless-stopped` (Task 7).

Commit points: Task 2 (new traefik tree), Task 8 (cleanup + docs) — plus push. If any validation fails mid-way, STOP and report; do not proceed to the next destructive task.

## Risks, tradeoffs, and open questions

**Risks**
- **LE rate limit (5 duplicate certs/registered-domain/week):** 1 prod wildcard already issued this week by Caddy; Traefik needs 1 more → fine. Do NOT loop-restart Traefik on failure (each failed attempt still consumes order quota); debug with logs first.
- **Wrong-zone DNS-01:** a private `chadrbean.com` zone exists; mitigated by `AWS_HOSTED_ZONE_ID=Z030496415CSA0E3T50AY` in `.env`.
- **Priority trap:** Traefik's default router priority = rule length; the catch-all HostRegexp outranks `Host()` rules. Mitigated with explicit `priority:` (documented in dynamic.yml + README).
- **`network_mode: host` on rootless podman:** binds the real host netns (intended — sslh needs 127.0.0.1:18443). If podman-compose rejects `network_mode: host` alongside other network keys, remove any `networks:` stanza (the compose file above has none).
- **Old Caddy certs destroyed** (apex `chadrbean.com`, `me.chadrbean.com`): nothing routes them today; re-issuable if needed later.
- **sslh restart blip** (Task 7): 8443 down ~2s; user confirmed nothing depends on live connections.

**Tradeoffs**
- Traefik official image (no Containerfile/build step) vs Caddy's custom xcaddy build — simpler, fewer moving parts.
- File provider (static routers) vs docker provider (label-based auto-discovery): file provider chosen — only one host-service upstream today, YAGNI on discovery.
- Keeping `caddy/` + IAM user name `hermes-caddy-dns01` as-is: renames are cosmetic and would touch live credentials; skipped deliberately.

**Open questions (non-blocking)**
- ACME `email:` for expiry notices is unset (Caddy ran without one too). Add Chad's email to `traefik.yml` → `certificatesResolvers.route53.acme.email` if wanted.
- Rename IAM user `hermes-caddy-dns01` → e.g. `traefik-dns01`? Out of scope; keys unchanged either way.
- Pin Traefik to an exact minor (e.g. `traefik:v3.6`) after first `podman pull` reports the resolved version? `v3` float chosen for simplicity.
