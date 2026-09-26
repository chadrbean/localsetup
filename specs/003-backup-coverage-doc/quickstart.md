# Quickstart: validate the backup coverage audit

Run from the repo root after implementation.

1. **Document exists and is short** (FR-001, FR-012):
   `wc -l docs/BACKUP-COVERAGE.md` → about 150 or fewer.
2. **One table, fixed header, only valid verdicts** (FR-002):
   `grep -c '^| Service | Path | Holds | Backed up | Note |' docs/BACKUP-COVERAGE.md` → `1`;
   every data row's 4th cell is `yes`, `no` or `partly`.
3. **Every stack covered** (FR-003, SC-001):
   `for d in litellm monitoring traefik serpbear homepage jenkins hermes decap gsc-mcp caddy fail2ban sshd sysctl automation kopia; do grep -q "^| $d" docs/BACKUP-COVERAGE.md || echo "missing $d"; done`
   → no output.
4. **Gap rules quoted verbatim** (SC-002): for each backticked rule in the Gaps section,
   `grep -qxF '<rule>' kopia/.kopiaignore` succeeds.
5. **Restore paths are covered** (US3, FR-008): every path Restore order restores *from*
   appears in a `yes` or `partly` row; step 1 names the repository password and S3
   credentials as out-of-band.
10. **No secret values** (FR-014): `gitleaks detect --no-git --source docs/BACKUP-COVERAGE.md`
    (or the catalog's gitleaks check) finds nothing.
11. **Update trigger** (FR-015): `grep -n -i 'kopiaignore' CLAUDE.md` shows the new line
    naming when to update the doc.
6. **Links** (FR-008, FR-009): `grep -n 'kopia/README.md' docs/BACKUP-COVERAGE.md`;
   `grep -n 'BACKUP-COVERAGE.md' README.md CLAUDE.md` → a hit in each.
7. **kopia/ untouched** (FR-010, SC-004): `git diff --stat main -- kopia/` → empty.
8. **Repo gates** (FR-013, SC-005): `python3 ci/check_syntax.py` and the shellcheck
   command from `ci/checks.yml` pass.
9. **Spot-check one verdict by hand** (US1 scenario 2): e.g.
   `~/.local/share/containers/...` → matched by `/.local/share/*`, no later `!` rule → `no`.
   On the real host `kopia snapshot estimate /home/chad` can confirm (not available in CI).
