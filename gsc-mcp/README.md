# gsc-mcp — Google Search Console MCP Server

## What this is and why we built it

otbla.com uses a daily AI pipeline to discover and publish LA events. The pipeline was
producing content but we had no reliable way to know whether that content was ranking on
Google or getting indexed. The rank tracking tool (PowerSEO) was reporting positions via
Yahoo as a proxy for Google — which produced inaccurate numbers and errors like:

    TooManyRedirectsException: Too many redirects https://search.yahoo.com/_bv/v.gif?...

We validated this directly: PowerSEO said "LA EDM events" was ranking at position 21.
A real Google search via headless browser showed it at position 39-44. The data was wrong
because Yahoo was the actual data source, not Google.

The fix: connect directly to Google Search Console via the official API. GSC is the only
source that gives you what Google actually thinks — real positions, real clicks, real
impressions, pulled from the same database Google uses internally. No scraping, no proxies.


## What this does for otbla.com

The GSC MCP server (mcp-search-console) connects Hermes AI directly to GSC data.
You can ask plain-English questions and get real answers:

- "What keywords is otbla.com ranking for right now?"
- "Which EDM queries are getting impressions but zero clicks?"
- "Did yesterday's published posts get indexed by Google?"
- "Is the EDM category gaining or losing impressions vs last month?"
- "What keywords should we target for the next batch of posts?"

21 tools available covering: search analytics, URL inspection, sitemap management,
period comparisons, page-level performance, and indexing status.


## Role in the SEO stack

Three tools, three distinct jobs — no overlap:

    SerpBear (UI dashboard)
        - You pick the target keywords you want to rank for
        - Scrapes Google daily via SERP API
        - Shows position trends, alerts on movement
        - Visual: charts, history, notifications
        - Set-it-and-forget-it monitoring

    GSC MCP / Hermes (intelligence layer, on-demand)
        - Reads what Google already knows about otbla.com
        - Used conversationally — ask a question, get an answer
        - Finds opportunities you didn't know to look for
        - Informs which keywords to target in new posts
        - Validates posts got indexed after publishing
        - NO scheduled cron — on-demand only

    Events discovery pipeline (content production)
        - Publishes posts targeting the keywords GSC MCP identifies
        - Outcome feeds back into SerpBear to track if rankings moved

The workflow loop:

    GSC MCP (weekly check)
        find impressions with 0 clicks near page 1
        identify keyword gaps and content opportunities
              |
              v
    Pipeline authoring brief
        target those keywords in post titles and body
        publish via daily cron
              |
              v
    SerpBear (daily tracking)
        watch if new posts moved target keyword positions
        alert on rank changes
              |
              v
    GSC MCP (48h post-publish check)
        confirm new URLs got indexed
        measure click impact


## How we set this up (full history)

### Problem discovered

During a session on 2026-09-18, we investigated why PowerSEO's rank tracker was showing
positions for EDM keywords (21, 27, 28) that weren't visible when searching Google manually.
We set up a headless Brave browser with CDP remote debugging to scrape real Google results
and confirmed:

    "edm in la"        — GSC real position: 27    (tracker said 27 — coincidentally close)
    "edm los angeles"  — GSC real position: 24    (tracker said 28 — off)
    "la edm events"    — GSC real position: 44    (tracker said 21 — way off, stale Yahoo data)

The root cause: the Java stack trace showed AbstractYahooSearchEngineParser — PowerSEO was
using Yahoo to estimate Google positions, not scraping Google directly.

### CDP setup (side effect — now permanent)

During the investigation we fixed the systemd CDP browser service which was missing
--remote-allow-origins=*. The service at ~/.config/systemd/user/brave-cdp.service was
updated and is now used by the browser automation layer.

### Google Cloud project creation

Project: otbla-gsc-mcp
Created: 2026-09-18
Account: DaBeanMan808@gmail.com

Steps taken:
1. Created project otbla-gsc-mcp in Google Cloud Console
2. Enabled Search Console API (console.cloud.google.com/apis/library/searchconsole.googleapis.com)
3. Created OAuth 2.0 consent screen (External user type)
4. Created OAuth Desktop app client → downloaded client_secrets.json
5. OAuth blocked with "access_denied" — app in test mode, DaBeanMan808@gmail.com not
   recognized as a valid Google test user by the system
6. Pivoted to Service Account auth (no browser OAuth flow required):
   - Created service account: otbla-gsc-reader@otbla-gsc-mcp.iam.gserviceaccount.com
   - Downloaded JSON key → saved as service_account.json
   - Added service account email to otbla.com GSC property (Settings → Users → Add)
   - Permission level: siteFullUser
7. Confirmed working: list_properties returned sc-domain:otbla.com with siteFullUser access

### Hermes MCP registration

    hermes mcp add gsc --command "uvx" --args "mcp-search-console"
    hermes config set mcp_servers.gsc.env.GSC_CREDENTIALS_PATH \
        "/home/chad/git/localsetup/gsc-mcp/service_account.json"
    hermes config set mcp_servers.gsc.env.GSC_OAUTH_CLIENT_SECRETS_FILE \
        "/home/chad/git/localsetup/gsc-mcp/client_secrets.json"

Result: 21 tools loaded at session start under the gsc namespace.

### First real data pull (2026-09-18, last 28 days)

Top findings from get_search_analytics:

    Branded (working as expected)
    - "otbla.com"         pos 1     clicks: branded traffic
    - "out the box la"    pos 1     clicks: branded traffic

    EDM keywords (0 clicks, page 3-4 territory)
    - "edm los angeles"   pos 24.3  impressions: 3
    - "edm in la"         pos 27.3  impressions: 3
    - "la edm events"     pos 44.3  impressions: 3
    - "edm shows la"      pos 56    impressions: 1

    Near-page-1 opportunities (high priority)
    - "lucas museum soft opening"        pos 8.3   impressions: 3
    - "lucas museum of narrative art..."  pos 9     impressions: 3
    - "museo long beach"                 pos 3.8   impressions: 6  clicks: 1 (actual traffic!)
    - "murder mystery queen mary"        pos 10.5  impressions: 2  clicks: 1

    Insight: la-gems style content (specific venues/events) drives actual clicks.
    EDM category needs more content depth to move from page 3-4 to page 1.


## Files

    client_secrets.json     OAuth client secrets (gitignored — do not commit)
    service_account.json    Service account key (gitignored — do not commit)
    .env                    Active secrets paths (gitignored)
    .env.example            Template showing required variables
    README.md               This file


## Credentials and secrets

Secrets are gitignored. The .env file holds:

    GSC_OAUTH_CLIENT_SECRETS_FILE=/home/chad/git/localsetup/gsc-mcp/client_secrets.json
    GSC_CREDENTIALS_PATH=/home/chad/git/localsetup/gsc-mcp/service_account.json

The Hermes config (~/.hermes/config.yaml) has both env vars set under mcp_servers.gsc.env
so the server picks them up automatically at session start.


## Re-provisioning from scratch

If you need to rebuild this on a new machine or after losing the credentials:

1. Go to console.cloud.google.com → project otbla-gsc-mcp
2. IAM & Admin → Service Accounts → otbla-gsc-reader → Keys → Add Key → JSON
3. Save downloaded file as ~/git/localsetup/gsc-mcp/service_account.json
4. Verify service account is still a user on the GSC property:
   search.google.com/search-console → Settings → Users and permissions
   Should show: otbla-gsc-reader@otbla-gsc-mcp.iam.gserviceaccount.com (Full)
   If missing, re-add it.
5. Run: hermes mcp add gsc --command "uvx" --args "mcp-search-console"
6. Run: hermes config set mcp_servers.gsc.env.GSC_CREDENTIALS_PATH \
       "/home/chad/git/localsetup/gsc-mcp/service_account.json"
7. Start a new Hermes session — gsc tools will appear in the tool list


## Hermes config entry (current)

    mcp_servers:
      gsc:
        command: uvx
        args:
          - mcp-search-console
        enabled: true
        env:
          GSC_CREDENTIALS_PATH: /home/chad/git/localsetup/gsc-mcp/service_account.json
          GSC_OAUTH_CLIENT_SECRETS_FILE: /home/chad/git/localsetup/gsc-mcp/client_secrets.json


## Common queries

Ask Hermes any of these directly — the skill otbla-seo-keyword-research has the details.

Pre-authoring keyword brief (run before pipeline):
    "What keywords should we target for EDM posts this week?"
    "What queries are near page 1 with impressions but no clicks?"

Post-publish index check (run 48h after publish):
    "Check if yesterday's published posts got indexed"
    "Inspect these URLs: [list from report.json]"

Weekly performance review:
    "How is otbla.com performing in search this week?"
    "Which categories are gaining or losing impressions vs last month?"

Opportunity finding:
    "What keywords is Google showing us for that we don't have a post targeting yet?"
    "Which pages have the most impressions but lowest CTR?"


## Package info

    Package:    mcp-search-console (pip)
    Source:     github.com/AminForou/mcp-gsc
    Runtime:    uvx (no install needed, cached by uv)
    Cache:      ~/.cache/uv/archive-v0/ (managed by uv automatically)
    Version:    0.4.1 (September 2026)
    Auth mode:  Service account (no browser OAuth required)
