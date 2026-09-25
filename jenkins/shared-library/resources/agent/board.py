#!/usr/bin/env python3
"""GitHub Projects (v2) board client for the agent feature pipeline.

Stdlib only; auth via GH_TOKEN (classic PAT with `project` + `repo` scopes —
GitHub App installation tokens can't reach user-owned projects).

  board.py --config config.json setup                 create Stage/Run fields, check Status options
  board.py --config config.json claim --out claims.json
        move up to <wip> Ready issues per allowlisted repo to In Progress, write them as JSON
  board.py --config config.json set ITEM_ID [--status KEY] [--stage NAME|--clear-stage] [--run URL]
  board.py --config config.json list                  print every item with status/stage (debug)

See docs/AGENT-PIPELINE.md.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com/graphql"
STAGE_COLOR = "BLUE"


def gql(query, **variables):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("board.py: GH_TOKEN is not set")
    req = urllib.request.Request(
        API,
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Authorization": f"bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"board.py: GraphQL HTTP {e.code}: {e.read().decode()[:500]}")
    if body.get("errors"):
        sys.exit(f"board.py: GraphQL errors: {json.dumps(body['errors'])[:1000]}")
    return body["data"]


FIELDS_FRAGMENT = """
fields(first: 50) { nodes {
  ... on ProjectV2SingleSelectField { id name dataType options { id name } }
  ... on ProjectV2Field { id name dataType }
} }"""


class Board:
    def __init__(self, cfg):
        self.cfg = cfg
        p = cfg["project"]
        if not p.get("number"):
            sys.exit("board.py: project.number is 0 in config.json — create the project and set it (docs/AGENT-PIPELINE.md)")
        root = "organization" if p.get("ownerType") == "org" else "user"
        data = gql(
            f"query($owner: String!, $n: Int!) {{ {root}(login: $owner) {{ projectV2(number: $n) {{ id title url {FIELDS_FRAGMENT} }} }} }}",
            owner=p["owner"], n=int(p["number"]),
        )
        proj = data[root]["projectV2"]
        if not proj:
            sys.exit(f"board.py: project {p['owner']}#{p['number']} not found")
        self.id, self.title, self.url = proj["id"], proj["title"], proj["url"]
        self.fields = {f["name"]: f for f in proj["fields"]["nodes"] if f}

    def field(self, key, required=True):
        name = self.cfg["fields"][key]
        f = self.fields.get(name)
        if not f and required:
            sys.exit(f"board.py: project has no '{name}' field — run `board.py setup`")
        return f

    def option_id(self, key, option_name):
        f = self.field(key)
        for o in f.get("options", []):
            if o["name"].lower() == option_name.lower():
                return o["id"]
        sys.exit(f"board.py: field '{f['name']}' has no option '{option_name}'")

    def items(self):
        status, stage = self.cfg["fields"]["status"], self.cfg["fields"]["stage"]
        q = """query($id: ID!, $after: String, $status: String!, $stage: String!) { node(id: $id) { ... on ProjectV2 {
          items(first: 100, after: $after, orderBy: {field: POSITION, direction: ASC}) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id isArchived
              status: fieldValueByName(name: $status) { ... on ProjectV2ItemFieldSingleSelectValue { name } }
              stage: fieldValueByName(name: $stage) { ... on ProjectV2ItemFieldSingleSelectValue { name } }
              content { __typename
                ... on Issue { number title url state repository { nameWithOwner } }
                ... on DraftIssue { title }
                ... on PullRequest { number title url }
              }
            }
          } } } }"""
        after, out = None, []
        while True:
            conn = gql(q, id=self.id, after=after, status=status, stage=stage)["node"]["items"]
            for n in conn["nodes"]:
                if n["isArchived"]:
                    continue
                c = n.get("content") or {}
                out.append({
                    "itemId": n["id"],
                    "status": (n.get("status") or {}).get("name"),
                    "stage": (n.get("stage") or {}).get("name"),
                    "type": c.get("__typename"),
                    "repo": (c.get("repository") or {}).get("nameWithOwner"),
                    "number": c.get("number"),
                    "title": c.get("title"),
                    "url": c.get("url"),
                    "state": c.get("state"),
                })
            if not conn["pageInfo"]["hasNextPage"]:
                return out
            after = conn["pageInfo"]["endCursor"]

    def set_select(self, item_id, key, option_name):
        f = self.field(key)
        gql("""mutation($p: ID!, $i: ID!, $f: ID!, $o: String!) { updateProjectV2ItemFieldValue(
                input: {projectId: $p, itemId: $i, fieldId: $f, value: {singleSelectOptionId: $o}}) { clientMutationId } }""",
            p=self.id, i=item_id, f=f["id"], o=self.option_id(key, option_name))

    def set_text(self, item_id, key, text):
        f = self.field(key, required=False)
        if not f:
            return
        gql("""mutation($p: ID!, $i: ID!, $f: ID!, $t: String!) { updateProjectV2ItemFieldValue(
                input: {projectId: $p, itemId: $i, fieldId: $f, value: {text: $t}}) { clientMutationId } }""",
            p=self.id, i=item_id, f=f["id"], t=text)

    def clear(self, item_id, key):
        f = self.field(key, required=False)
        if not f:
            return
        gql("""mutation($p: ID!, $i: ID!, $f: ID!) { clearProjectV2ItemFieldValue(
                input: {projectId: $p, itemId: $i, fieldId: $f}) { clientMutationId } }""",
            p=self.id, i=item_id, f=f["id"])


def repo_cfg(cfg, repo):
    for name, over in cfg["repos"].items():
        if repo and name.lower() == repo.lower():
            return {**cfg["defaults"], **over, "repo": name}
    return None


def cmd_setup(board, cfg, _args):
    print(f"project: {board.title}  {board.url}")
    stage_name, run_name = cfg["fields"]["stage"], cfg["fields"]["run"]
    if stage_name not in board.fields:
        opts = [{"name": s, "color": STAGE_COLOR, "description": f"agent pipeline: {s}"} for s in cfg["stages"]]
        gql("""mutation($p: ID!, $n: String!, $o: [ProjectV2SingleSelectFieldOptionInput!]) { createProjectV2Field(
                input: {projectId: $p, dataType: SINGLE_SELECT, name: $n, singleSelectOptions: $o}) { clientMutationId } }""",
            p=board.id, n=stage_name, o=opts)
        print(f"created field '{stage_name}' ({', '.join(cfg['stages'])})")
    else:
        have = {o["name"] for o in board.fields[stage_name].get("options", [])}
        missing = [s for s in cfg["stages"] if s not in have]
        print(f"field '{stage_name}' exists" + (f" — MISSING options (add in the UI): {missing}" if missing else ""))
    if run_name not in board.fields:
        gql("""mutation($p: ID!, $n: String!) { createProjectV2Field(
                input: {projectId: $p, dataType: TEXT, name: $n}) { clientMutationId } }""", p=board.id, n=run_name)
        print(f"created field '{run_name}'")
    else:
        print(f"field '{run_name}' exists")
    status = board.fields.get(cfg["fields"]["status"])
    have = {o["name"] for o in (status or {}).get("options", [])}
    want = ["Backlog", *cfg["statuses"].values(), "Done"]
    missing = [s for s in want if s not in have]
    if missing:
        print(f"Status field is missing options — add them in the project UI (Settings > Status): {missing}")
        return 1
    print(f"Status options OK: {want}")
    return 0


def cmd_claim(board, cfg, args):
    st = cfg["statuses"]
    items = board.items()
    busy = {}
    for it in items:
        if it["status"] == st["inProgress"] and it["repo"]:
            busy[it["repo"].lower()] = busy.get(it["repo"].lower(), 0) + 1
    claims = []
    for it in items:
        if it["status"] != st["ready"]:
            continue
        if it["type"] != "Issue":
            print(f"skip {it['itemId']} '{it['title']}': {it['type']} — convert the draft to an issue in an allowlisted repo")
            continue
        rc = repo_cfg(cfg, it["repo"])
        if not rc:
            print(f"skip {it['repo']}#{it['number']}: repo not in config.json allowlist")
            continue
        if it["state"] != "OPEN":
            print(f"skip {it['repo']}#{it['number']}: issue is {it['state']}")
            continue
        key = it["repo"].lower()
        if busy.get(key, 0) >= int(rc["wip"]):
            print(f"wait {it['repo']}#{it['number']}: WIP {busy[key]}/{rc['wip']}")
            continue
        board.set_select(it["itemId"], "status", st["inProgress"])
        board.clear(it["itemId"], "stage")
        busy[key] = busy.get(key, 0) + 1
        claims.append({"itemId": it["itemId"], "repo": it["repo"], "issue": it["number"],
                       "title": it["title"], "url": it["url"]})
        print(f"claim {it['repo']}#{it['number']} '{it['title']}'")
    with open(args.out, "w") as f:
        json.dump(claims, f, indent=2)
    print(f"{len(claims)} claimed")
    return 0


def cmd_set(board, cfg, args):
    if args.status:
        board.set_select(args.item, "status", cfg["statuses"][args.status])
    if args.clear_stage:
        board.clear(args.item, "stage")
    elif args.stage:
        board.set_select(args.item, "stage", args.stage)
    if args.run is not None:
        board.set_text(args.item, "run", args.run)
    return 0


def cmd_list(board, _cfg, _args):
    for it in board.items():
        print(f"{it['status'] or '-':12} {it['stage'] or '-':10} {it['repo'] or it['type']}#{it['number'] or ''} {it['title']}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("setup")
    sub.add_parser("list")
    c = sub.add_parser("claim")
    c.add_argument("--out", required=True)
    s = sub.add_parser("set")
    s.add_argument("item")
    s.add_argument("--status", choices=["ready", "inProgress", "blocked", "review"])
    s.add_argument("--stage")
    s.add_argument("--clear-stage", action="store_true")
    s.add_argument("--run")
    args = ap.parse_args()
    with open(args.config) as f:
        cfg = json.load(f)
    board = Board(cfg)
    return {"setup": cmd_setup, "claim": cmd_claim, "set": cmd_set, "list": cmd_list}[args.cmd](board, cfg, args)


if __name__ == "__main__":
    sys.exit(main())
