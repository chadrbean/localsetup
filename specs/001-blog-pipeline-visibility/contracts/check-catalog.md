# Contract: Check catalog (`blogLosAngeles/ci/checks.yml`)

The catalog is the single source of truth for what each check is, whether it blocks, and where it runs. Three things consume it:
- `runCheck` in the shared library, which reads it at runtime with `readYaml`
- `run_smoketests.py --category`
- `render_catalog.py`, which produces `docs/ci-gates.md`

## Format

```yaml
version: 1
checks:
  - id: internal-links
    stage: checks/tests
    category: blocking
    threshold: 0 broken internal links in the built site
    runs_on: [pr, main, cron]
    purpose: Every internal href resolves to a built page
    command: python3 scripts/run_smoketests.py --only internal_links
    waiver: override-only

  - id: pipeline-tests
    stage: checks/tests
    category: blocking
    scope: [automation/events-discovery/]
    threshold: all unit tests pass
    runs_on: [pr, main, cron]
    purpose: events-discovery automation behaves as tested
    waiver: override-only

  - id: surfaced-backlog
    stage: data-health
    category: monitoring
    threshold: <= 400 future events stuck at 'surfaced'
    runs_on: [daily]
    purpose: Detect events re-trapped in the discovery queue
    waiver: none
```

## Rules

1. `id` values are unique. For smoketests, `id` is the check's file stem with the `check_` prefix removed and `_` replaced by `-`.
2. `category: monitoring` MUST have a `stage` that is a site-health job (`security-live`, `seo-live-crawl` or `data-health`). It MUST NOT be a `delivery` stage.
3. `scope` is allowed only with `category: blocking`.
4. `run_smoketests.py --category C` runs the smoketests whose effective category is `C`:
   - `--category change` means blocking + advisory
   - `--exclude-category monitoring` is the default in `delivery`
5. Adding a check file without a catalog entry fails `check_catalog_coverage` (blocking).
