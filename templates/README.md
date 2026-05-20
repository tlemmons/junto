# Junto agent system-prompt templates

The canonical home for the cross-cutting operational rules every junto agent
follows. Inject via `claude --append-system-prompt-file <rendered.md>` at
launch. Do NOT duplicate these rules into committed `CLAUDE.md` files in
component repos — `CLAUDE.md` is for repo orientation only.

## What's here

```
templates/
├── junto-system-prompt.md.tmpl    ← base template (required for every agent)
├── overlays/
│   └── example.md                 ← annotated overlay starter (copy + edit)
├── render.sh                      ← reference renderer (POSIX shell)
├── render.ps1                     ← reference renderer (PowerShell)
└── README.md                      ← this file
```

## Why a template, not a static file

Per-launch dynamic content. Agent name, project, role, the shared-memory URL
your deployment uses, optional API key for authenticated servers, and whether
the junto-inbox plugin is loaded — all differ per launch. Mechanical
`{{var}}` substitution at launch time keeps the prompt fresh without forking
the source of truth.

A static rendered file would (a) duplicate across every agent, (b) drift as
people edit copies, and (c) fail to template per-deployment URLs/keys.

## Two layers: base, and optional project overlay

### Base (required)

`junto-system-prompt.md.tmpl` is the cross-cutting layer. Applies to every
junto agent, every project. Contains: identity assignment, `memory_start_session`
contract, session lifecycle, the parking checklist, marker handling, peer
routing defaults, memory hygiene rules, context discipline, and the
prohibition list. ~150 lines after rendering with defaults.

If a rule belongs here, it must apply to **every** junto agent regardless of
project. If it doesn't, it belongs in an overlay (or in `CLAUDE.md` as
repo-specific orientation).

The base also contains two **renderer-injected conditional blocks**:

- **`{{auth_block}}`** — one-line statement about API key. Populated by the
  renderer from `--api-key` (or "none configured" if absent).
- **`{{plugin_session_block}}`** — multi-line block clarifying that the
  junto-inbox plugin's session is distinct from the agent's session.
  Injected only when `--plugin-present true`; omitted entirely otherwise.

Adopters do NOT provide values for these directly — the renderer derives
them from other args.

### Project overlay (optional)

A project overlay file is appended after the base, with the same `{{var}}`
substitutions. **It is truly optional** — many projects work fine with the
base alone. Reach for an overlay only when your project has rules that don't
apply to other junto projects.

**When you need an overlay:**

- Your project has multiple peer agents and you want a team-roster snippet so
  every agent knows who else exists.
- You have a project-specific escalation rule (e.g. "any cross-team
  architectural call goes to coordinator first").
- Your project uses non-default tooling (e.g. `bun` not `npm`, or a custom
  build script).
- You have project-specific scopes (read-only paths, restricted directories).

**When you don't need an overlay:**

- You're a single-agent project (memory, control, inbox running solo in their
  own repo). Base covers everything.
- Your project's specifics are repo-orientation content — those belong in
  `CLAUDE.md` in the project's repo, not in a system-prompt overlay.
- You're tempted to add an overlay just because you can. Don't. Bias toward
  base-only and add an overlay later if a real need surfaces.

**Overlay rules** (enforced by convention, not the renderer):

1. **Additive only.** Overlays may ADD rules. They may NOT contradict or
   override base. If you find yourself wanting to say "ignore base's rule X
   for this project," that's a sign base needs to change — file a backlog
   item against `junto`.
2. **Use the same variable surface** (see below).
3. **Keep it tight.** Target 30-60 lines. If your overlay is longer than
   base, something is wrong.

**Overlay naming.** Real overlays in active use should be named
`overlays/<project>.md` (e.g. `overlays/nimbus.md`). Use the bare name; do
not prefix with `_`. The `example.md` starter is the only special-cased file.

See `overlays/example.md` for an annotated starter file.

### Per-agent extras (third layer, also optional)

Some projects have one agent with rules that don't apply to other agents in
the same project (e.g. `coordinator@nimbus` has Q1-escalation rules the team
agents don't). For that case, the renderer supports an `--extras` argument
that appends a per-agent file after the overlay.

This is the rarest layer. Most projects never need it.

## Variable surface

All three layers share the same substitution variables:

| Variable                | Required | Example                              | Notes                                                                                  |
| ----------------------- | -------- | ------------------------------------ | -------------------------------------------------------------------------------------- |
| `{{agent}}`             | yes      | `memory`, `coordinator`, `inbox`     | Used in `memory_start_session(claude_instance=...)`                                    |
| `{{project}}`           | yes      | `junto`, `nimbus`                    | Used in `memory_start_session(project=...)`                                            |
| `{{role}}`              | yes      | `"Shared MCP knowledge-base server"` | One-line; surfaces in agent directory                                                  |
| `{{shared_memory_url}}` | yes      | `http://localhost:8080/mcp` (local peer) or `http://<peer-host>:8080/mcp` (LAN peer) | Per-deployment; if you run a peer, point at the peer's URL, not at primary |
| `{{cwd}}`               | no       | `~/work/your-repo`                   | Defaults to the renderer's `pwd`. **Pass explicitly** — renderer pwd is rarely right. Maps to `working_directory=...` on `memory_start_session`. |
| `{{plugin_present}}`    | no       | `true` / `false`                     | Whether `--channels plugin:junto-inbox@...` is on the launch. Drives the conditional `{{plugin_session_block}}`. |
| `{{api_key}}`           | no       | `tom-web-key-...`                    | Required if server has `MCP_AUTH_ENABLED=true`. Drives the `{{auth_block}}`.           |

**Safety net:** both renderers fail loud (exit 3) if any `{{...}}` token
remains unresolved after substitution. A misconfigured launcher cannot ship
a system prompt with raw `{{agent}}` strings in it.

## Wire conventions (template-baked)

These conventions appear in the template body and any consumer code that
parses the system prompt or related artifacts must agree on:

- **State spec naming:** `state:<agent>` (e.g. `state:memory`,
  `state:coordinator`). The park checklist directs every agent to write a
  spec at this name; coordinators and dashboards that aggregate "all agent
  states" rely on this convention.
- **System sender identity:** `system@<project>` (e.g. `system@junto`) for
  server-synthesized notices (push-control recovery, schema alerts).
- **Marker strings:** `[REQUIRES REVIEW]` for destructive-keyword gates,
  `[SYSTEM NOTICE]` for system-sender messages. Plugins emit these as
  prepended-to-body strings.

Changing any of these is a breaking change requiring coordinated bumps
across junto-memory, junto-inbox, junto-control, and this template.

## Renderer usage

### POSIX shell (`render.sh`)

Portable to bash 3.2 (macOS default) and bash 4+. Avoids GNU/BSD `sed -i`
divergence. Escapes sed metacharacters.

```bash
# Minimal — base only, stdout, no auth
./render.sh \
    --agent memory --project junto \
    --role "Junto memory MCP server" \
    --shared-memory-url http://localhost:8080/mcp \
    --cwd "$HOME/sharedUtils/junto/junto-memory"

# With overlay, with auth, write to a temp file, feed claude
PROMPT_FILE=$(./render.sh \
    --agent coordinator --project nimbus \
    --role "Nimbus team coordinator" \
    --shared-memory-url http://localhost:8080/mcp \
    --cwd "$HOME/work/nimbus" \
    --plugin-present true \
    --api-key "$JUNTO_API_KEY" \
    --overlay ./overlays/nimbus.md \
    --out /tmp/nimbus-coordinator-prompt.md)

claude --append-system-prompt-file "$PROMPT_FILE" \
       --channels plugin:junto-inbox@tlemmons-junto-inbox
```

### PowerShell (`render.ps1`)

PowerShell 5.1 + PowerShell 7. Explicit `-Encoding utf8` on every file
operation to preserve UTF-8 content (em-dashes etc.) on stock Windows.

```powershell
$promptFile = .\render.ps1 `
    -Agent inbox -Project junto `
    -Role "junto-inbox channel plugin" `
    -SharedMemoryUrl http://localhost:8080/mcp `
    -Cwd "C:\code\claudeTerminal" `
    -PluginPresent $true `
    -ApiKey $env:JUNTO_API_KEY `
    -Out "$env:TEMP\junto-inbox-prompt.md"

claude --append-system-prompt-file $promptFile `
       --channels plugin:junto-inbox@tlemmons-junto-inbox
```

### Vendoring vs fetching

Three reasonable distribution patterns:

1. **Fetch fresh per launch.** Launcher curls the raw template URL from
   GitHub at startup. Always current; fails on network. Good for dev boxes
   with reliable connectivity.
2. **Clone `tlemmons/junto` to `~/.junto/`.** Launcher uses the local copy;
   re-runs `git pull` periodically. Resilient offline, drifts if you forget
   to pull.
3. **Vendor into your launcher repo.** Copy `templates/` into your launcher
   project at a known sha. Frozen until you update; reproducible.

The local clone directory name is your choice — `~/.junto/`, `~/junto/`,
`~/code/junto/`, whatever. The canonical github repo is
always `tlemmons/junto`. Renderer scripts use relative paths within
`templates/` so they don't care about the parent directory's name.

For workshop-grade deployments use (1) or (2). For production launchers,
(3). The renderer scripts don't care which.

## Adopter checklist

Adding a new junto agent to your project:

1. Decide if you need an overlay. Most don't.
2. Get the template (clone/curl/vendor as above).
3. **Audit your global `~/.claude/CLAUDE.md` (and any user-level CLAUDE.md
   that loads first) for identity-assignment rules.** The base template owns
   identity now; pre-existing global rules can race against it. Either
   remove the global identity-assignment rules or scope them so they only
   trigger when no template-injected identity is present.
4. Write a launcher script that:
   - Resolves the variables (`{{agent}}`, `{{project}}`, `{{role}}`,
     `{{shared_memory_url}}`, `{{cwd}}`, optionally `{{plugin_present}}`
     and `{{api_key}}`).
   - Calls `render.sh` / `render.ps1` to produce a temp file.
   - Invokes `claude --append-system-prompt-file <tmpfile>` plus any
     `--channels plugin:junto-inbox@...` arg if the inbox plugin is wanted.
5. Thin the project's `CLAUDE.md` to repo orientation only. Drop any
   operational-rules sections that overlap with the base template. Add a
   line like:
   `Source of truth for system rules: tlemmons/junto/templates/junto-system-prompt.md.tmpl`.
   See [`docs/claude-md-migration.md`](../docs/claude-md-migration.md) for
   an annotated before/after example with placeholder substitution.
6. Smoke test: launch the agent; in its first turn, ask "what is your name
   and your `memory_start_session` contract?" The answer should reflect the
   rendered prompt.

## Versioning and compatibility

This template is versioned with the umbrella repo's git history. See
[../CHANGELOG.md](../CHANGELOG.md) for adopter-visible deltas. Pin to a
specific commit if you need reproducibility. Otherwise track `main` —
breaking changes are called out in the changelog.

**Variable surface is the public contract.** Adding a new optional variable
is backwards-compatible. Removing or renaming one is a breaking change and
gets a CHANGELOG entry.

**Implicit compatibility with junto-memory.** The template body hardcodes
`memory_start_session` argument names, marker strings, and the `state:<agent>`
spec convention. If junto-memory renames any of those, the template needs
a coordinated bump. Adopters: if you upgrade junto-memory across a major
version, check CHANGELOG to see whether the template needs to upgrade with
it.

## Reporting issues

Found a rule that's wrong, missing, or contradicts what you observe?

- File a backlog item against project `junto`:
  `memory_add_backlog_item(project="junto", title="template: ...", ...)`.
- Or open an issue at https://github.com/tlemmons/junto.
- Don't fork the template silently — the whole point is that there's one
  source of truth.
