#!/usr/bin/env python3
"""Materialize junto skills into <cwd>/.claude/skills/ before Claude Code starts.

Consumer side of interface:skill-materialization-v0. Claude Code discovers
skills at startup, so this has to run on the agent's box before `claude` is
exec'd; the server (a container elsewhere) cannot write these files itself.

One request: POST <base>/export-skills {project, role, working_directory}
(+ Bearer on auth servers). No MCP handshake, no junto session.

Safety rules (from the contract):
  * Prune ONLY on HTTP 200 with a `skills` list. Any other outcome means
    "state unknown": write nothing, delete nothing. A DB outage on the server
    returns 503/500, never 200 {count: 0}.
  * Only files carrying the provenance footer (<!-- junto skill ...) are
    junto-managed. A hand-authored SKILL.md is never overwritten or pruned.
  * Write only when content changed.
Each materialized skill dir gets its own `.gitignore` (`*`), so consumer repos
ignore junto's files without anyone editing a tracked .gitignore, and
hand-authored skills beside them stay visible to git.

Opt-in: does nothing unless JUNTO_MATERIALIZE_SKILLS=1 (env, ~/.junto/config,
or a directory's .junto-identity). Best-effort: always exits 0, so a launch
never fails because of this step.

Usage:
  junto-skills.py --project P --agent A [--cwd DIR] [--url URL] [--api-key KEY]
URL may be the server base (http://host:8080) or the MCP url (.../mcp);
defaults to $JUNTO_MEMORY_URL, then http://localhost:8080. The key defaults
to $JUNTO_API_KEY (omit on keyless home servers).
"""
import argparse
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

MARKER = "<!-- junto skill "
TIMEOUT = 8


def log(msg):
    print(f"junto: skills: {msg}", file=sys.stderr)


def base_url(url):
    url = (url or "http://localhost:8080").rstrip("/")
    return url[: -len("/mcp")] if url.endswith("/mcp") else url


def fetch(url, api_key, project, agent, cwd):
    body = json.dumps({"project": project, "role": agent, "working_directory": cwd}).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(f"{url}/export-skills", data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            data = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        log(f"server returned HTTP {e.code}; leaving .claude/skills/ untouched")
        return None
    except Exception as e:  # noqa: BLE001 - unreachable, timeout, bad JSON
        log(f"export failed ({e}); leaving .claude/skills/ untouched")
        return None
    skills = data.get("skills") if isinstance(data, dict) else None
    if not isinstance(skills, list):
        log("response has no skills list; leaving .claude/skills/ untouched")
        return None
    return skills


def is_managed(path):
    try:
        return MARKER in path.read_text(encoding="utf-8")
    except Exception:  # noqa: BLE001
        return False


def safe_dest(root, relpath):
    """<name>/SKILL.md under root, or None for anything that escapes it."""
    rel = pathlib.PurePosixPath(relpath or "")
    if rel.is_absolute() or ".." in rel.parts or len(rel.parts) != 2 or rel.name != "SKILL.md":
        return None
    return root / rel.parts[0] / "SKILL.md"


def materialize(root, skills):
    wanted, written, kept = set(), 0, 0
    for s in skills:
        content = s.get("content") or ""
        dest = safe_dest(root, s.get("relpath"))
        if dest is None or MARKER not in content:
            log(f"skipping malformed export entry {s.get('relpath')!r}")
            continue
        wanted.add(dest)
        if dest.exists():
            if not is_managed(dest):
                log(f"{dest.parent.name}: hand-authored SKILL.md exists, not overwriting")
                continue
            if dest.read_text(encoding="utf-8") == content:
                kept += 1
                continue
        # Only a dir this script creates gets the ignore-everything file; an
        # existing dir may hold a person's own files that git should still see.
        created = not dest.parent.exists()
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_name(".SKILL.md.tmp")
        tmp.write_text(content, encoding="utf-8")
        tmp.replace(dest)
        if created:
            (dest.parent / ".gitignore").write_text("*\n", encoding="utf-8")
        written += 1

    pruned = 0
    for existing in root.glob("*/SKILL.md"):
        if existing in wanted or not is_managed(existing):
            continue
        existing.unlink()
        ignore = existing.parent / ".gitignore"
        if ignore.exists() and ignore.read_text(encoding="utf-8").strip() == "*":
            ignore.unlink()
        try:
            existing.parent.rmdir()
        except OSError:
            pass  # the dir holds other files; leave it
        pruned += 1
    return written, kept, pruned


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--agent", required=True)
    ap.add_argument("--cwd", default=os.getcwd())
    ap.add_argument("--url", default=os.environ.get("JUNTO_MEMORY_URL"))
    ap.add_argument("--api-key", default=os.environ.get("JUNTO_API_KEY", ""))
    args = ap.parse_args()

    if os.environ.get("JUNTO_MATERIALIZE_SKILLS", "0") != "1":
        return
    skills = fetch(base_url(args.url), args.api_key, args.project, args.agent, args.cwd)
    if skills is None:
        return
    root = pathlib.Path(args.cwd) / ".claude" / "skills"
    try:
        written, kept, pruned = materialize(root, skills)
    except Exception as e:  # noqa: BLE001
        log(f"write failed ({e})")
        return
    log(f"{written + kept} current ({written} written, {pruned} pruned) in .claude/skills/")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 - never block a launch
        log(f"skipped ({e})")
