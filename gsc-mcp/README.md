# gsc-mcp — Google Search Console MCP Server

MCP server that connects Google Search Console to Hermes AI.
Package: `mcp-search-console` (AminForou/mcp-gsc on GitHub).
Runs via `uvx mcp-search-console` — no install needed, uvx handles it.

## What it does

Gives Hermes direct read access to GSC data for otbla.com:
- Real keyword rankings (clicks, impressions, CTR, avg position)
- Page-level performance
- URL indexing status
- Sitemap health
- Period-over-period comparisons

## Credentials

OAuth flow (Desktop app) — one-time browser login, token saved to
`~/.cache/mcp-search-console/token.json` by the server.

Secrets live in `.env` (git-ignored). See `.env.example`.

## Setup (already done — notes for re-provisioning)

1. Google Cloud Console → project `otbla-gsc-mcp`
2. APIs & Services → Enable Search Console API
3. Credentials → OAuth 2.0 Client ID → Desktop app → download JSON
4. Save JSON contents as `GOOGLE_CLIENT_SECRETS_JSON` in `.env`
5. Hermes MCP entry in `~/.hermes/config.yaml` points to `uvx mcp-search-console`
6. First run triggers browser OAuth → token auto-saved

## Hermes config entry

```yaml
mcp_servers:
  gsc:
    command: uvx
    args: [mcp-search-console]
    env:
      GOOGLE_CLIENT_SECRETS_FILE: /home/chad/git/localsetup/gsc-mcp/client_secrets.json
    enabled: true
```

## Token location

`~/.cache/mcp-search-console/token.json` — auto-refreshed by the server.
Delete this file to force re-authentication.

## Skill

`otbla-seo-keyword-research` Hermes skill wraps common queries:
- "What keywords is otbla.com ranking for?"
- "How is the EDM category performing?"
- "Which pages have the most impressions but low CTR?"
