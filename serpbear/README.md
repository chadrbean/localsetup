# serpbear — keyword rank tracker

[SerpBear](https://github.com/towfiqi/serpbear) as a rootless `podman-compose`
stack, published at `https://serpbear.chadrbean.com` through Traefik. Run
`podman-compose <args>` from this directory; secrets are in `.env`.

## Components

| Piece | Detail |
|---|---|
| Image | `docker.io/towfiqi/serpbear:3.1.0` (pinned; check tags before bumping) |
| Port | `127.0.0.1:3002` → container `3000` (loopback only; 3000 is Grafana) |
| Data | bind mount `~/.local/share/serpbear/data` → `/app/data` (SQLite DB + `settings.json`) |
| Secrets | `serpbear/.env` (git-ignored), Google key file in `~/.local/share/serpbear/secrets/` (chmod 700 dir, 600 files) |
| Edge | `traefik/dynamic.yml` router/service `serpbear` (wildcard cert, `fail2ban` middleware) |
| DNS | Route53 A `serpbear.chadrbean.com` (terraform `modules/dns` in `~/git/aws-infrastructure`), IP kept current by `scripts/awsChadHomeIp.sh` |

`userns_mode: keep-id:uid=1001,gid=1001` maps the image's `nextjs` user (1001)
to host uid 1000 so the bind-mounted data dir is writable rootlessly.

## Files

    serpbear/
      docker-compose.yml   stack definition
      .env.example         variables (copy to .env)
      .env                 real secrets (git-ignored)

## First run

    cd serpbear
    cp .env.example .env         # then fill in; SECRET/APIKEY: openssl rand -hex 32
    mkdir -p ~/.local/share/serpbear/{data,secrets}
    podman-compose up -d
    podman ps --filter name=serpbear
    curl -sI http://127.0.0.1:3002/

Log in with `USER` / `PASSWORD` from `.env`. On a fresh DB the log shows
migration "No description found for table" errors — expected; the app creates
the tables after the migrations run.

## Rankings scraper

SerpBear needs a scraping provider (ScrapingRobot, SerpApi, ValueSerp, …).
Choose it in **Settings → Scraper** in the UI; the key is stored in
`settings.json` in the data directory.

## Google Search Console

SerpBear reads Search Console through a **service account** (no OAuth):

1. Google Cloud project → enable **Search Console API** → IAM → create a service
   account → create a JSON key.
2. Search Console → each property → Settings → Users and permissions → add the
   service-account email (Restricted is enough).
3. Put the email in `SEARCH_CONSOLE_CLIENT_EMAIL` and the key's `private_key` in
   `SEARCH_CONSOLE_PRIVATE_KEY` (single line, newlines as literal `\n`) in `.env`,
   keep the JSON in `~/.local/share/serpbear/secrets/`, then
   `podman-compose up -d --force-recreate`.

SerpBear has no Google Analytics integration.

## Persistence / backup

Everything stateful is under `~/.local/share/serpbear/` — `podman-compose down`
and image rebuilds keep it. Back up that directory.

## Adding/changing the hostname

See the "new app" checklist in the root `CLAUDE.md`: Traefik route, `/etc/hosts`
hairpin line (`192.168.1.30 serpbear.chadrbean.com`), terraform DNS record,
`DNS_RECORDS` in `scripts/awsChadHomeIp.sh`.
