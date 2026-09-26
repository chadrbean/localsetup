# Data model: Backup coverage audit (003)

The deliverable is a Markdown document, so the "entities" are the rows and sections in it.

## Service (stack directory)

| Field | Rule |
|---|---|
| name | a repo top-level directory: `litellm`, `monitoring`, `traefik`, `serpbear`, `homepage`, `jenkins`, `hermes`, `decap`, `gsc-mcp`, `caddy` (archived), `fail2ban`, `sshd`, `sysctl`, `automation`, `kopia` |
| included when | it has a compose file, bind mounts, a named volume, or installs files on a host (`docs/HOSTS.md`) |

`ci/`, `scripts/`, `docs/`, `specs/` are not services; `scripts/awsChadHomeIp.sh` is covered
under its installed path (`/usr/local/bin`).

## Host location (one table row)

| Field | Rule |
|---|---|
| service | one of the above; a service has ≥ 1 row (FR-003) |
| path | `~`-relative for `/home/chad`, absolute otherwise; named volumes written as `~/.local/share/containers/storage/volumes/<name>` |
| holds | ≤ ~8 words: config / secrets / DB / logs / cache / history |
| backed up | exactly `yes`, `no` or `partly` |
| note | the deciding rule (quoted) or "not in a backup source" or "git"; "cannot be determined from the repo" where so (FR-011) |

Rows for several paths with the same verdict and reason may be merged (e.g. all `/etc`
drop-ins of one service) to keep the document under ~150 lines.

## Ignore rule

A verbatim line of `kopia/.kopiaignore`, quoted in backticks. Order matters; the verdict is
the last matching rule, and a rule under an excluded directory never applies.

## Coverage verdict

| Value | Meaning |
|---|---|
| yes | the path and all its contents are in a source and no rule excludes them (build-artifact rules such as `node_modules/` aside) |
| partly | the directory is entered but some named children are excluded, or only named children are re-included |
| no | an ignore rule excludes it, or it is outside every backup source |

## Gap

A `no`/`partly` location that holds secrets, a database or non-regenerable state. Fields:
path, what is lost, and either the exact excluding rule or "outside every backup source".
Deliberate exclusions (build history, caches, logs, metrics) stay in the table only.

## Restore step

Ordered item: service, backed-up path(s) to restore from (each must be `yes`/`partly` in
the table), and what it unblocks. Commands are a link to `kopia/README.md`.
