# Landing page for all public *.chadrbean.com admin interfaces (me.chadrbean.com)

## Goal

Stand up `https://me.chadrbean.com` as a single authenticated landing page
listing every admin interface currently exposed through Traefik
(`traefik/dynamic.yml`), each with a live up/down + latency indicator, using
the existing open-source dashboard **Homepage** (`gethomepage/homepage`)
rather than building a bespoke app.

## Current context / assumptions

- Repo: `~/git/localsetup`. Edge proxy is Traefik v3 (`traefik/`), one
  compose stack per app, `network_mode: host`, `dynamic.yml` = file-provider
  routes, wildcard cert `*.chadrbean.com` (Route53 DNS-01), public entry is
  `:443` via `sslh` → `127.0.0.1:18443`. Read `traefik/README.md` before
  touching anything here — it documents several sharp edges (see Pitfalls
  0-4 at the top of `dynamic.yml`, especially PITFALL 4 about `watch: false`
  requiring a `podman restart traefik` after certain edits, and the
  dashboard-auth-must-be-listed-on-the-router trap).
- `me.chadrbean.com` is already a DNS-only A record today (see
  `traefik/README.md` line ~29: "`me.chadrbean.com` is a DNS-only record
  ..., not routed" and `scripts/awsChadHomeIp.sh` `DNS_RECORDS`). No Traefik
  router exists for it yet — this plan adds one.
- Currently routed public admin surfaces (from `traefik/dynamic.yml`,
  confirmed live with `podman ps` / `curl` during investigation):
  | Host | Backend | Auth today |
  |---|---|---|
  | `hermes.chadrbean.com` | `127.0.0.1:9119` | Hermes's own |
  | `traefik.chadrbean.com` | `api@internal` (dashboard) | Traefik basic auth (`dashboard-auth`) |
  | `otbla.chadrbean.com` / `otbla-local.chadrbean.com` | `127.0.0.1:1313` (Hugo) | none (public blog) |
  | `grafana.chadrbean.com` | `127.0.0.1:3000` | Grafana's own login |
  | `accounting.chadrbean.com` | `127.0.0.1:3001` | app's own login (NextAuth, confirmed 401/302 from access log) |
  | `librecrawl.chadrbean.com` | `127.0.0.1:5000` | unknown, check at implementation time |
  | `serpbear.chadrbean.com` | `127.0.0.1:3002` | app's own login |
  | `litellm.chadrbean.com` | `127.0.0.1:4000` | LiteLLM's own (`/ui`) |
  This list is the source of truth to port into Homepage's `services.yaml` —
  re-read `dynamic.yml` at implementation time in case it changed.
  `otbla`/`otbla-local` are a public blog, not an "admin interface" — include
  them in a separate "Public sites" group, not mixed with admin tools, but
  do include them (user said "all our traefik sites").
- Free TCP ports confirmed via `ss -tlnp` during investigation: 3000 (Grafana),
  3002 (SerpBear), 4000 (LiteLLM), 5000 (librecrawl), 1313 (Hugo), 9119
  (Hermes), 8081 (decap), 9090/9115/3100 (monitoring, loopback). **3005 is
  free** — use it for Homepage's internal listen port (picked because it's
  unused and close to the other app ports; re-verify with the `ss` command
  in Task 3 before committing, since another agent/process may have taken it
  since this investigation).
- Rootless podman, host uid 1000 = uid 0 in containers (see root
  `CLAUDE.md`). `podman-compose` is the compose tool (never `docker`).
  Persistent app data goes in `~/.local/share/<app>/`, bind-mounted, not
  named volumes (per root `CLAUDE.md` convention) — Homepage's `config/`
  directory follows that pattern here.
- `htpasswd` and `pyyaml` are already installed on the host (verified).
  Passwordless `sudo` is available for this user.
- No `docker.sock`/`podman.sock` bind-mount will be used for the Docker
  auto-discovery feature of Homepage in the MVP — the service list is
  static YAML (`services.yaml`), matching how every other app in this repo
  is configured (declarative files, not runtime discovery), and avoids
  handing a container root-equivalent access to the podman socket. This can
  be revisited later as an optional enhancement (see Risks).

## Architecture / proposed approach

Deploy **Homepage** (`gethomepage/homepage`, MIT-licensed, actively
maintained, the de-facto standard self-hosted "single pane of glass"
dashboard with 100+ service integrations) as a new podman-compose stack
`homepage/`, following the exact same pattern as `serpbear/`: pinned image
tag, `.env` for secrets, bind-mounted config dir under
`~/.local/share/homepage/config`, loopback-only port publish, fronted by a
new Traefik router for `me.chadrbean.com` gated with **HTTP basic auth**
(reuse the `dashboard-auth` middleware pattern already proven for
`traefik.chadrbean.com`, but with its own credentials/htpasswd file so
Homepage and the Traefik dashboard don't share a password). Homepage's
built-in `siteMonitor` (formerly `ping`) field gives free up/down + latency
"metrics" per card, satisfying the "nice to have" ask, with zero extra
credentials to manage — deeper per-app widgets (Grafana dashboards embedded,
Traefik router counts) are an optional Phase 2, not required for the landing
page to be useful.

## Step-by-step tasks

### Phase 0 — pre-flight checks (no changes yet)

1. Re-verify the current router/service table in
   `traefik/dynamic.yml` hasn't drifted since planning:

       cd ~/git/localsetup
       grep -A2 '^  routers:' -A200 traefik/dynamic.yml | grep -E '^\s{4}\w+:$|rule:|service:'

   Expected: the same 8 app routers listed in "Current context" above
   (hermes, dashboard/traefik, otbla, otbla-local(+cms), grafana, accounting,
   librecrawl, serpbear, litellm-root/litellm). If the list differs, update
   the services table in this plan's Task 5 accordingly before proceeding.

2. Confirm port 3005 is still free:

       ss -tlnp 2>/dev/null | grep ':3005 ' || echo "3005 is free"

   Expected output: `3005 is free`. If it's taken, pick the next free port
   (3006, ...) and use it consistently through the rest of this plan.

3. Check what each backend serves at `/` to note in `services.yaml`
   descriptions and to catch anything down:

       for p in 9119 3000 3001 5000 3002 4000; do
         echo "== $p =="; curl -sk -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$p/ ;
       done

   Expected: mostly `200`/`302`/`401` (all "alive"); note any `000`
   (connection refused) — that backend's card should still be added to
   `services.yaml` but you know going in its `siteMonitor` will show red
   until it's started.

### Phase 1 — Homepage stack

4. Create the stack directory and data dir:

       mkdir -p ~/git/localsetup/homepage
       mkdir -p ~/.local/share/homepage/config

5. Write `~/git/localsetup/homepage/docker-compose.yml`:

   ```yaml
   # Homepage (https://github.com/gethomepage/homepage) — landing page for
   # every *.chadrbean.com admin interface, published at
   # https://me.chadrbean.com through Traefik (basic-auth gated; Homepage
   # itself has no login of its own, so the Traefik middleware IS the auth).
   # Config is static YAML (services.yaml/settings.yaml/widgets.yaml/
   # bookmarks.yaml), not Docker-socket auto-discovery — keeps this
   # container from needing access to the podman socket.
   # Data/config persists in a bind mount under ~/.local/share/homepage/config
   # (not a named volume), per this repo's convention — see root CLAUDE.md.
   # Port binds to loopback only; Traefik (host network) is the only public
   # entry point.
   services:
     homepage:
       image: ghcr.io/gethomepage/homepage:v2.4.0
       container_name: homepage
       restart: unless-stopped
       environment:
         HOMEPAGE_ALLOWED_HOSTS: me.chadrbean.com
         PORT: "3005"
       ports:
         - "127.0.0.1:3005:3005"
       volumes:
         - ~/.local/share/homepage/config:/app/config
   ```

   Note: no `env_file` yet — nothing secret lives in `services.yaml` in this
   plan (no widget API keys), so an `.env`/`.env.example` pair is optional.
   Skip it for now; add one later only if a Phase 2 credentialed widget is
   added (see Risks).

6. Write `~/.local/share/homepage/config/settings.yaml`:

   ```yaml
   title: chadrbean.com admin
   headerStyle: clean
   statusStyle: dot
   layout:
     Admin:
       style: row
       columns: 3
     Public sites:
       style: row
       columns: 3
   ```

7. Write `~/.local/share/homepage/config/services.yaml` — one entry per
   router found in Task 1, `siteMonitor` pointed at the PUBLIC https URL
   (not the loopback backend — that gives the same up/down signal you'd see
   from outside, since it goes through Traefik same as a real visitor) and
   `href` also the public URL:

   ```yaml
   - Admin:
       - Hermes:
           icon: si-anthropic
           href: https://hermes.chadrbean.com/
           siteMonitor: https://hermes.chadrbean.com/
           description: Hermes agent dashboard
       - Traefik:
           icon: traefik.png
           href: https://traefik.chadrbean.com/dashboard/
           siteMonitor: https://traefik.chadrbean.com/dashboard/
           description: Edge proxy dashboard (basic auth)
       - Grafana:
           icon: grafana.png
           href: https://grafana.chadrbean.com/
           siteMonitor: https://grafana.chadrbean.com/
           description: Metrics, logs, alerting
       - LiteLLM:
           icon: si-litellm
           href: https://litellm.chadrbean.com/ui
           siteMonitor: https://litellm.chadrbean.com/ui
           description: LLM gateway admin UI
       - Accounting:
           icon: si-nextdotjs
           href: https://accounting.chadrbean.com/
           siteMonitor: https://accounting.chadrbean.com/
           description: Wave-style bookkeeping app
       - SerpBear:
           icon: si-google
           href: https://serpbear.chadrbean.com/
           siteMonitor: https://serpbear.chadrbean.com/
           description: SEO rank tracker
       - LibreCrawl:
           icon: si-scrapy
           href: https://librecrawl.chadrbean.com/
           siteMonitor: https://librecrawl.chadrbean.com/
           description: Web crawler UI
   - Public sites:
       - otbla.com:
           icon: si-hugo
           href: https://otbla.chadrbean.com/
           siteMonitor: https://otbla.chadrbean.com/
           description: LA events blog (Hugo)
       - otbla local edit:
           icon: si-hugo
           href: https://otbla-local.chadrbean.com/
           siteMonitor: https://otbla-local.chadrbean.com/
           description: Decap CMS local editing
   ```

   Icon names use https://gethomepage.dev icon conventions (`si-*` =
   Simple Icons, `traefik.png`/`grafana.png` = bundled dashboard-icons pack)
   — if a chosen `si-*` slug 404s in the UI, drop the `icon:` line for that
   entry rather than guessing further; it's cosmetic only.

8. Write an empty `~/.local/share/homepage/config/bookmarks.yaml`
   (Homepage requires the file to exist even if unused):

   ```yaml
   []
   ```

9. Write an empty `~/.local/share/homepage/config/widgets.yaml` (header
   widgets — skip for MVP, revisit in Phase 2):

   ```yaml
   []
   ```

10. Start the stack and verify it's serving locally:

        cd ~/git/localsetup/homepage
        podman-compose up -d
        sleep 3
        curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3005/

    Expected: `200`. If not, check `podman logs homepage` for a YAML parse
    error (most common cause: bad indentation in `services.yaml`).

### Phase 2 — Traefik route + auth

11. Generate a basic-auth hash for `me.chadrbean.com` (separate credentials
    from the Traefik dashboard's — don't reuse `TRAEFIK_DASHBOARD_AUTH`):

        NEWPW='...'   # pick one, don't paste it in chat/logs
        HASH=$(htpasswd -nbB chad "$NEWPW")
        echo "$HASH"   # single $, e.g. chad:$2y$05$...

12. Add the credential to `traefik/.env` (single `$`, do NOT escape —
    `traefik/README.md` "Do not `$` → `$$` escape this value" applies here
    too, same env_file mechanism):

        printf 'ME_DASHBOARD_AUTH=%s\n' "$HASH" >> ~/git/localsetup/traefik/.env

    Also add a placeholder line (no value) to `traefik/.env.example` for
    documentation, mirroring how `TRAEFIK_DASHBOARD_AUTH` is documented
    there.

13. Add a new middleware and router + service block to
    `traefik/dynamic.yml`. Insert the middleware next to `dashboard-auth`:

    ```yaml
        me-dashboard-auth:
          basicAuth:
            users:
              - "{{ env `ME_DASHBOARD_AUTH` }}"
    ```

    Insert the router next to the `grafana` router (**priority must be >
    1**, copy the `serpbear` router pattern exactly):

    ```yaml
        me:
          rule: Host(`me.chadrbean.com`)
          entryPoints: [websecure]
          service: me
          priority: 100
          middlewares: [me-dashboard-auth, fail2ban]
          tls:
            certResolver: route53
            domains:
              - main: "*.chadrbean.com"
    ```

    Insert the service next to the `serpbear` service:

    ```yaml
        me:
          loadBalancer:
            servers:
              - url: "http://127.0.0.1:3005"
    ```

    **Middlewares order matters for the pitfall documented in
    `traefik/README.md`**: `me-dashboard-auth` MUST be listed on the `me`
    router's `middlewares:` — defining the middleware block alone does
    nothing.

14. Recreate Traefik so it picks up the new `.env` value (PITFALL 4 in
    `dynamic.yml`'s header: `watch: false`, and env values are baked in at
    container creation — a plain `restart` won't see the new `.env` var
    either):

        cd ~/git/localsetup/traefik
        podman-compose -f docker-compose.yaml up -d --force-recreate

15. Add the local hairpin-NAT `/etc/hosts` line (needed to test from this
    box per `traefik/README.md`'s "Local access from this host" section):

        echo '192.168.1.30 me.chadrbean.com' | sudo tee -a /etc/hosts

    (Confirm `192.168.1.30` is still this host's LAN IP first: `ip -4 addr
    show | grep 192.168` — use whatever IP is actually assigned if it
    differs from the other entries already in `/etc/hosts`.)

16. Verify auth is enforced and the page loads with credentials:

        curl -sk -o /dev/null -w '%{http_code}\n' https://me.chadrbean.com/
        # expected: 401

        curl -sk -o /dev/null -w '%{http_code}\n' -u "chad:$NEWPW" https://me.chadrbean.com/
        # expected: 200

    (Use the real password chosen in Task 11, entered directly in this
    command — do not write it to any file.)

17. Add DNS + IP-refresh coverage so `me.chadrbean.com`'s A record and the
    hourly IP-refresh cron both know to keep behaving — **re-check**:
    `me.chadrbean.com` is already in `scripts/awsChadHomeIp.sh`
    `DNS_RECORDS` (confirmed in Phase 0) and already has a Terraform-managed
    Route53 record (`~/git/aws-infrastructure/terraform/modules/dns/main.tf`,
    confirmed in investigation) — **no DNS change needed**, this step is
    just the explicit "new app checklist" callout from `CLAUDE.md` so a
    future reader doesn't redo it. Skip straight to Task 18.

### Phase 3 — docs

18. Update `traefik/README.md`'s "Local access from this host (hairpin
    NAT)" list to include `me.chadrbean.com` (it currently stops at
    `serpbear.chadrbean.com` and is already missing `litellm.chadrbean.com`
    — add both while you're in there, noting the drift).

19. Create `~/git/localsetup/homepage/README.md` following the `serpbear/
    README.md` structure: components table (image, port, data dir, secrets,
    edge, DNS), first-run steps, how to add a new service card (edit
    `services.yaml`, `podman-compose restart homepage` — no rebuild needed,
    Homepage hot-reloads YAML changes), backup note (
    `~/.local/share/homepage/config` is the only stateful path).

20. Update root `CLAUDE.md`'s "Stacks & conventions" bullet list to mention
    `homepage/` alongside `litellm/`, `monitoring/`, `traefik/`, `serpbear/`.

### Phase 4 — verification pass

21. Full external-facing check (simulates what `me.chadrbean.com` visitors
    see, still testable from this host via the hairpin `/etc/hosts` entry):

        curl -sk -u "chad:$NEWPW" https://me.chadrbean.com/ | grep -o '<title>[^<]*' 
        # expected: <title>chadrbean.com admin

    Then visually confirm in a browser: log in, all 9 cards render, each
    shows a status dot, click through 2-3 links to confirm they land on the
    right app.

22. Confirm fail2ban middleware is still active on the new router (it's in
    the `middlewares:` list from Task 13, but verify the plugin didn't
    error out cold-starting against a route it's never seen):

        podman logs traefik 2>&1 | tail -50 | grep -i fail2ban

    Expected: no error lines mentioning `me` or the plugin; absence of
    errors is success here (the plugin doesn't log per-request activity).

23. Commit:

        cd ~/git/localsetup
        git add homepage/ traefik/dynamic.yml traefik/.env.example \
                traefik/README.md CLAUDE.md
        git status   # confirm traefik/.env and homepage/config are NOT staged
                     # (.env is git-ignored repo-wide already; config dir
                     # lives outside the repo under ~/.local/share, so it
                     # can't be staged)
        git commit -m "feat(homepage): add me.chadrbean.com landing page for admin sites"

## Tests / validation

This is infra/config, not application code — no unit tests apply. The
validation is the command+expected-output pairs embedded in each task above
(Tasks 2, 3, 10, 16, 21, 22). Treat each as a gate: don't move to the next
task until the current one's command returns the expected output. If a
command's actual output doesn't match, stop and debug before continuing —
don't stack further changes on top of an unverified state.

## Risks, tradeoffs, and open questions

- **Homepage has no login of its own** — Traefik basic auth is the only
  gate. That's consistent with how `traefik.chadrbean.com` is already
  protected in this repo, so it's not a new risk pattern, but it does mean
  anyone who gets the `me.chadrbean.com` basic-auth credentials sees the
  full topology of every internal service (ports, which apps exist) even if
  they can't log into the apps themselves. Acceptable given this is a home
  network behind fail2ban + a single external IP, matching the existing
  Traefik dashboard's risk profile.
- **Static `services.yaml` vs. Docker auto-discovery**: chosen deliberately
  to avoid mounting `podman.sock` into a new container (that socket is
  effectively root-equivalent access to every container on the host). The
  tradeoff is manual upkeep — a new app added to `dynamic.yml` needs a
  matching manual entry in `services.yaml` or it won't show up on the
  landing page. Worth a one-line addition to the "Add an app" checklist in
  `traefik/README.md` (not included as a formal task above — flag to the
  user, low priority).
- **`siteMonitor` hits the PUBLIC https URL, not loopback**: means Homepage
  depends on Traefik + DNS + the internet round-trip to report status, so
  during an ISP outage every card would show red even though the backends
  are healthy — this is intentional (it's exactly what a real visitor
  experiences) but worth knowing if it's confusing during a home-internet
  blip.
- **Phase 2 (not in this plan, explicitly deferred)**: credentialed widgets
  (Grafana dashboard counts, Traefik router/service counts via the
  `traefik` widget type, LiteLLM spend) are all supported by Homepage and
  would add real "metrics", matching the user's "nice to have" wish more
  fully — deferred because each needs its own secret wired through
  `HOMEPAGE_VAR_*` env-var substitution into `services.yaml`, and this repo
  treats new secrets as a deliberate, reviewed step (see `.env.example`
  pattern used everywhere). Revisit after the MVP is confirmed working.
- **Icon slugs (`si-anthropic`, `si-litellm`, etc.) are best-effort** — not
  verified against the live Simple Icons/dashboard-icons catalog during
  planning; if wrong they just fail to render (no functional impact). Note
  left in Task 7 to drop rather than debug.
- **Image tag `v2.4.0`** was the latest release found via web search at
  planning time — re-check https://github.com/gethomepage/homepage/releases
  at implementation time in case a newer version shipped, per this repo's
  "pin, don't `:latest`" convention (see `serpbear/README.md`).
