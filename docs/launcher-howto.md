# The Junto launcher — a pattern, not a program

There is no single "junto launcher" you must run. A launcher is just a thin
wrapper you put in front of `claude` (or your agent CLI) that does two required
things and any number of optional ones. **Different machines assemble different
subsets** — a headless server wants tmux and unattended permissions; a laptop
wants none of that. Treat the `junto` script in this repo as **one reference
example**, copy the pieces you need, and drop the rest.

This doc documents the *contract* so you can build (or trim) your own.

---

## What a launcher MUST do

1. **Set the agent's identity** — export `JUNTO_AGENT` and `JUNTO_PROJECT` so
   the session registers as the right agent in the right project.
2. **Load the inbox channel** — start the agent with the junto-inbox plugin so
   peer messages get pushed into the live session:

   ```bash
   claude --channels plugin:junto-inbox@tlemmons-junto-inbox
   ```

   Without `--channels`, the agent still reads memory over MCP, but peer
   push-notifications are silently dropped. This one line is the difference
   between "connected to inbox" and not.

A minimum viable launcher is genuinely just:

```bash
#!/usr/bin/env bash
export JUNTO_AGENT=memory JUNTO_PROJECT=junto
exec claude --channels plugin:junto-inbox@tlemmons-junto-inbox "$@"
```

Everything below is optional sugar layered on top.

---

## Optional building blocks (pick per machine)

### Identity resolution (instead of hardcoding)

So one launcher works in every project directory, resolve identity from the CWD
in this precedence:

1. **`.junto-identity`** file (env-style, wins if present) — the explicit
   override. Drop this in any agent dir when autodetect can't work:

   ```
   JUNTO_AGENT=networking
   JUNTO_PROJECT=networking
   ```

2. **`.claude-identity`** file (nimbus convention: `JUNTO_INSTANCE=` /
   `JUNTO_PROJECT=`).

3. **`CLAUDE.md` autodetect** — grep for the canonical identity line
   `**Your name is: \`X\`** (project: \`Y\`)`. ⚠️ If a project's CLAUDE.md
   phrases identity any other way, autodetect fails and (without a
   `.junto-identity`) the launcher falls back to plain `claude` with **no
   inbox**. When in doubt, drop a `.junto-identity`.

### tmux attach-or-create (SSH-survivable long-running agents)

For always-on agents on a remote box, wrap the launch so a dropped SSH session
doesn't kill the agent:

```bash
tmux new-session -A -s "junto-$JUNTO_AGENT" -c "$PWD" -- <relaunch-self>
```

`-A` attaches if the session exists, creates otherwise. Gate it behind an
opt-out (`JUNTO_NO_TMUX=1`) and skip it when already inside tmux (`$TMUX` set).
Laptops usually skip this entirely.

### Unattended permission mode

Autonomous agents that must not stall on a permission prompt add
`--dangerously-skip-permissions` (skips ALL permission checks — only for
machines/agents you intend to run unattended). Interactive workstations leave it
off. Make it opt-out (e.g. `JUNTO_NO_BYPASS=1`) so a human can reclaim prompts.

### Skill materialization

Before starting the agent, export the project's active skills to
`.claude/skills/` so the client's native matcher fires them mid-task:

```
memory_export_skills(project, role) -> write each SKILL.md under .claude/skills/
```

The server can't write these files itself — the launcher does, on the box where
the agent runs. Machines that don't use skills skip this.

### Terminal title

Cosmetic but handy for multi-pane setups:

```bash
printf '\033]0;[%s] Claude Code\007' "$JUNTO_AGENT"
```

---

## Reference examples in this repo

- **`junto`** (this repo) — a fuller launcher with a first-run machine/identity
  **setup wizard** (`--setup`), CLAUDE.md autodetect, and skill materialization.
  Good starting point for a new box you want to bootstrap interactively.
- A **minimal, tmux-wrapping** variant (identity resolve → tmux attach-or-create
  → `--channels`) is the right shape for a headless always-on server. It's a
  ~40-line script; assemble it from the blocks above.

Neither is "the" launcher. Copy what fits, and expect your box to differ.

---

## Gotchas

- **`--channels` is load-bearing.** Missing it = no inbox, silently.
- **Identity autodetect is brittle to CLAUDE.md wording.** Prefer an explicit
  `.junto-identity` for anything that isn't a stock component CLAUDE.md.
- **The plugin runs `bun ./server.ts`.** If `bun` isn't on the launching
  shell's PATH, junto-inbox silently no-ops (PID markers appear, no delivery).
  Ensure `bun` is on PATH in whatever environment the launcher execs into.
