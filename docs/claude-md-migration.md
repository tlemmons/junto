# Migrating a project CLAUDE.md to template + thin orientation

This walks through splitting a typical "everything in CLAUDE.md" project into
the two-file pattern the umbrella template assumes:

- **`templates/junto-system-prompt.md.tmpl`** (cross-cutting operational rules,
  injected at launch via `--append-system-prompt-file`) — already exists in
  `tlemmons/junto`; you don't write this.
- **Thinned `CLAUDE.md`** in your project repo — only repo orientation.
- **Optional `overlays/<project>.md`** — only project-specific operational
  rules that don't belong in the cross-cutting template.

Case study: a single-agent MCP-server-style repo whose monolithic CLAUDE.md
runs ~220 lines and mixes the three concerns. Placeholders below stand in for
the real values:

| Placeholder            | Meaning                                                            |
| ---------------------- | ------------------------------------------------------------------ |
| `<project>`            | Project slug (the value passed to `memory_start_session(project=)`) |
| `<agent>`              | Agent name (e.g. `memory`, `server`, `frontend`)                   |
| `<repo>`               | Source repo / working-dir folder name                              |
| `<COMPONENT_NAME>`     | Human-friendly component name (e.g. "Memory server")               |
| `<DB_PORT>`            | Database port number                                               |
| `<APP_PORT>`           | Application port number                                            |
| `<SERVICE_NAME>`       | Systemd unit or docker container name                              |
| `<PROJECT_ROOT>`       | Absolute path to repo working dir                                  |
| `<PEER_AGENT>`         | Name of a peer agent in the same project (if any)                  |

---

## Step 1 — Classify every section of your current CLAUDE.md

Each top-level section maps to one of three fates:

- **KEEP** — repo orientation. What the codebase is, where things live,
  domain-specific terminology, infrastructure facts, what's safe to touch.
- **CUT** — operational rule already in the base template. Delete; the
  template will inject it on launch.
- **MOVE → overlay** — project-specific operational rule. Belongs in an
  optional `overlays/<project>.md`. ONLY do this if the rule genuinely
  doesn't apply to every junto agent.

### Worked example: section-by-section classification

```
# <COMPONENT_NAME> (one-line tag-line)                       │ KEEP — orientation
Component of the <project> suite. <short purpose>.            │

## Claude Identity (REQUIRED — DO THIS FIRST)                │ CUT — identity is
**Your name is: `<agent>`** ...                              │   in base template
Run these IMMEDIATELY:                                       │
1. /rename <agent>                                           │
2. set terminal title                                        │
3. memory_start_session(...)                                 │
   memory_list_backlog(...)                                  │
   memory_get_messages()                                     │

## Project Roster                                            │ MOVE → overlay
The <project> project has these agents:                      │   (only needed if
| <agent>     | Role 1 | Working dir                 |       │    you have >1
| <PEER_AGENT>| Role 2 | Working dir                 |       │    agent in the
                                                             │    project)

## Rename aliases (active until <DATE>)                      │ KEEP — project-
A 30-day alias period from <old-name> → <agent> ...          │   specific factual
                                                             │   detail; not
                                                             │   operational

## Key Files                                                 │ KEEP — orientation
- `server.py` — entry point                                  │
- `src/<repo>/` — tool implementations                       │
- `start.sh` — service startup                               │

## Infrastructure                                            │ KEEP — orientation
- DB: localhost:<DB_PORT>                                    │
- App: localhost:<APP_PORT>                                  │
- Systemd: `<SERVICE_NAME>`                                  │

## Common Operations                                         │ KEEP — orientation
```bash                                                      │
docker compose build <svc> && sudo systemctl restart ...     │
docker logs <SERVICE_NAME>                                   │
```                                                          │

## Scope                                                     │ KEEP — project-
Full dev access to all files in this folder.                 │   specific trust
Coordinate with <PEER_AGENT> via memory_send_message.        │   scope (terse;
                                                             │   could also live
                                                             │   in overlay if
                                                             │   long)

## Startup Macros                                            │ MOSTLY CUT
| go     | Gather context, present briefing, WAIT           │   Base template
| sync   | Same as go                                       │   covers the
| status | Same as go but lighter                           │   contract; if
| park   | Parking checklist                                │   your macro
                                                             │   semantics
                                                             │   differ
                                                             │   (e.g. you call
                                                             │   them something
                                                             │   else), keep a
                                                             │   minimal mapping
                                                             │   in CLAUDE.md.

### `go`                                                     │ CUT — same as
1. Run identity startup ...                                  │   base lifecycle
2. Gather state, messages, backlog ...                       │
6. STOP and wait for user approval                           │

### `park` — Mandatory checklist                             │ CUT — base
1. Register functions                                        │   template's
2. Record learnings                                          │   parking
3. Acknowledge messages                                      │   checklist is
4. Update state spec                                         │   the canonical
5. memory_end_session                                        │   version

## Turn-End Check                                            │ CUT — base
Before any turn handing back: get messages, filter blockers  │   covers this

## Inbound Cross-Project Messaging Rules                     │ MIXED
- Triage by category in priority order                       │   The defaults
- Don't decide Q1 for sender's project                       │   are in base.
- Do answer factual questions about <project> itself         │   The phrase
- Reply with in_response_to                                  │   "factual
- Don't echo 'received, working on it'                       │   questions
                                                             │   about <project>
                                                             │   itself" is
                                                             │   project-
                                                             │   specific →
                                                             │   move to
                                                             │   overlay if
                                                             │   relevant.

## Memory Hygiene — Recency Rules                            │ CUT — base
1. Check created/updated                                     │
2. Prefer newer                                              │
3. Verify >2 weeks                                           │
...                                                          │

## Non-Negotiable Rules                                      │ MOSTLY CUT
1. Never leave a stub method                                 │   Base covers
2. Document existing protocol before changing                │   1-3, 6.
3. Read existing code that handles same concern              │   Items 4-5 are
4. Do not rename fields without approval                     │   project-
5. Answer 'fresh agent in another project tries this' test   │   specific (the
6. Fail loud on MCP transport                                │   "exact shapes
                                                             │   `<project>`
                                                             │   returns"
                                                             │   framing is
                                                             │   specific to a
                                                             │   protocol
                                                             │   owner) → keep
                                                             │   in overlay or
                                                             │   thinned
                                                             │   CLAUDE.md.

## Context Management                                        │ CUT — base
1. Use Task subagents for research                           │
2. Find before read                                          │
3. Filter memory queries                                     │
4. Park before you die                                       │

## Pattern Reference                                         │ KEEP —
The transferable park/go pattern: spec name `pattern:        │   orientation
park-go`                                                     │   (where to
                                                             │   look)

## Architecture Reference                                    │ KEEP —
Full system tour: spec `architecture:<project>-v1`           │   orientation
```

The pattern that emerges: orientation + factual project state stays;
operational rules go away.

---

## Step 2 — Write the thinned CLAUDE.md

After classification, the CLAUDE.md drops from ~220 lines to ~50-70. Concrete
shape:

```markdown
# <COMPONENT_NAME>

Component of the <project> suite. <short purpose>.

> System rules for junto agents are injected at launch via
> [tlemmons/junto](https://github.com/tlemmons/junto) — see
> `templates/junto-system-prompt.md.tmpl`. THIS file documents the codebase
> only; do not duplicate operational rules here.

## Project Roster (factual, not operational)

The `<project>` project has these agents:

| Agent          | Role                              | Working dir    |
|----------------|-----------------------------------|----------------|
| `<agent>`      | <short role>                      | <PROJECT_ROOT> |
| `<PEER_AGENT>` | <short role>                      | <peer path>    |

(If your project has more than ~3 agents OR cross-agent routing rules,
move this table to `overlays/<project>.md` instead.)

## Rename aliases

A 30-day alias period from `<old-name>` to `<agent>` is active until
`<DATE>`. After expiry, old-name reconnects will fail.

## Key Files

- `server.py` — entry point
- `src/<repo>/` — tool implementations
- `start.sh` — service startup wrapper (called by systemd)
- `docker-compose.yml` — <list services>

## Infrastructure

- **Database:** localhost:<DB_PORT>
- **Application:** localhost:<APP_PORT>
- **Systemd:** `<SERVICE_NAME>` (main), <other units>

## Common Operations

```bash
# Restart server
docker compose build <svc> && sudo systemctl restart <SERVICE_NAME>

# View logs
docker logs <SERVICE_NAME>

# Health
curl -s http://localhost:<APP_PORT>/health
```

## Scope

Full development access to all files in this folder. Cross-component
coordination goes via `memory_send_message`.

## Architecture / pattern references

- Architecture spec: `architecture:<project>-v1`
- Park/go pattern: `pattern:park-go` (shared spec; do not redefine here)
```

That's it. ~50 lines. Everything else is in the template.

---

## Step 3 — Decide whether you need an overlay

Read your CLAUDE.md again. After the cut, did you have any sections you
classified as "MOVE → overlay"? If yes, write `overlays/<project>.md` in
the umbrella repo (or in your launcher's local mirror). If not, skip this
step entirely — most projects don't need an overlay.

The overlay rule (also stated in `templates/README.md`): additive only,
never override base. If you're about to write "ignore base's rule about X
for this project," stop — that means base needs to change, not your
overlay.

Concrete overlay candidates from the case study above:

- The team-roster table, **if** your project has more than ~3 agents or
  multi-team routing.
- The "factual questions about `<project>` itself" answering policy, if
  your project's agent is a protocol owner and other projects ask about it.
- A project-Q1 escalation rule (e.g., "anything touching two teams routes
  to coordinator first") — only present in genuinely multi-agent projects.

If your project has none of those, your overlay would be empty. Don't
create one.

---

## Step 4 — Wire your launcher

Whatever script launches `claude` for this agent (bash, PowerShell, or a
shortcut command) must:

1. Compute the six required vars (agent, project, role, shared-memory URL,
   cwd, optionally api-key + plugin-present).
2. Run `render.sh` / `render.ps1` to produce a temp file (with `--overlay`
   if you wrote one).
3. Invoke `claude --append-system-prompt-file <tmpfile>` plus any
   `--channels plugin:junto-inbox@...` if you want the inbox plugin.

See `templates/README.md` § "Renderer usage" for full launcher examples.

---

## Step 5 — Verify

After the first launch with the new pipeline:

1. Open the launched agent and ask it: *"What is your agent name, project,
   role, and the `memory_start_session` contract?"* — answers should
   reflect the rendered template, not the old CLAUDE.md content.
2. Trigger your park macro. Confirm the agent walks through the parking
   checklist from the template (register functions / record learnings /
   ack messages / state spec / end_session), not a project-local
   duplicate.
3. Confirm marker handling: send a `[REQUIRES REVIEW]`-tagged test
   message. The agent should surface to you for approval, not auto-act.

---

## Common pitfalls

**Global `~/.claude/CLAUDE.md` still asserts identity.** Many setups have
a personal CLAUDE.md with identity-resolution rules that load before the
project's. After migration, those rules race with the template's identity
block. Fix: audit your global CLAUDE.md and either remove its
identity-assignment rules or scope them so they only trigger when no
template-injected identity is present.

**Duplicate parking checklist.** If the old project CLAUDE.md had its own
park checklist (often subtly different from the base template's), agents
will get confused about which to follow. Cut it cleanly; the template's
version is authoritative.

**"Repo orientation" creep.** Sections like "Non-Negotiable Rules" tend
to mix orientation and operational content. Be honest — if a line tells
the agent how to behave at runtime (don't do X, always do Y, escalate Z),
it's operational and either belongs in base or is project-specific
enough for the overlay. If it describes the codebase (this folder is
authoritative for X, that subdirectory implements Y), it stays in
CLAUDE.md.

**Trying to move CLAUDE.md content into the template instead of an
overlay.** Don't. The template lives in `tlemmons/junto` and is shared
across every project. Project-specific rules go in your overlay, not in
the canonical template.
