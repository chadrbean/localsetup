# Contract: `docs/BACKUP-COVERAGE.md` structure

The document is the feature's only external interface (read by the owner and by agents
working on #38). Its shape is fixed so later checks can rely on it.

1. `# Backup coverage (Kopia)` title, then ≤ 6 lines: sources backed up (the three from
   `kopia/README.md`), how rules are applied (last match wins; excluded dirs never
   entered), the date and the fact that `kopia/` was not changed.
2. `## Coverage` — exactly one table, header exactly:
   `| Service | Path | Holds | Backed up | Note |`.
   Backed-up cells contain only `yes`, `no` or `partly`.
3. `## Deliberately not backed up` — short bullets with the reason (Jenkins build history
   vs. what is kept to rebuild Jenkins; caches; logs/metrics; reinstallable installs).
4. `## Gaps` — one bullet per gap: **path** — what is lost — the excluding rule in backticks,
   copied verbatim from `kopia/.kopiaignore` (or "outside every backup source").
5. `## Restore order` — numbered list, dependencies first (secrets/edge/CI before
   dependents), ending with a link to `../kopia/README.md` for commands. Step 1 names the
   out-of-band prerequisites (Kopia repository password, S3 credentials) without values;
   gap services say what is restored and what is recreated.
6. `## Not determinable from the repo` — Zuriel's host contents and any path read from an
   untracked `.env` (e.g. `GOOGLE_SA_KEY_PATH`).

7. An update-trigger line (new stack/data dir, mount or volume change, `.kopiaignore`
   change), in the intro or at the end.

Constraints: ≤ ~150 lines; no secret values (FR-014); links are relative.

Inbound links (FR-009):
- `README.md` docs list: `- **[docs/BACKUP-COVERAGE.md](docs/BACKUP-COVERAGE.md)** — …`
- `CLAUDE.md` Stacks & conventions: one sentence appended near the Kopia bullets, including
  the update trigger (FR-015).
