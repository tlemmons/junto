# Getting started with junto

A first-time adopter's guide to wiring a Claude agent into the junto
coordination layer. The umbrella's job is to frame the bigger picture and
hand you off to the right component repo for each piece; this doc walks
from zero to "first agent talking to junto-memory" without assuming you've
read any other repo first.

If you're already running a junto deployment and just need the template's
variable surface, skip to [templates/README.md](../templates/README.md).

---

## What junto gives you

Junto is three layers that compose. You opt into as many as you need.

1. **A shared knowledge bus** — the [junto-memory](https://github.com/tlemmons/junto-memory)
   MCP server. Persists learnings, function-registry entries, specs, message
   threads, and audit logs across every agent that talks to it. The agent
   sees these via the `memory_*` MCP tools.
2. **A cross-cutting agent identity + operating rules** — the umbrella's
   [system-prompt template](../templates/). Injected at launch via
   `claude --append-system-prompt-file`. Every junto agent gets the same
   identity-assignment rules, `memory_start_session` contract, park
   checklist, and marker handling — without you duplicating that into
   every project's `CLAUDE.md`.
3. **Live in-session message delivery** *(optional)* — the
   [junto-inbox](https://github.com/tlemmons/junto-inbox) Claude Code
   plugin. Without it, agents see messages on `memory_get_messages`
   polling. With it, peer messages render as `<channel>` blocks at the top
   of the next turn. Opt-in; the base template degrades gracefully if it's
   absent.

A minimal junto setup uses layers 1 and 2. Layer 3 becomes interesting
when you have multiple agents coordinating in real time.

---

## Before you start

You need:

- **A junto-memory MCP server reachable from your machine.** Either:
  - Connect to an existing shared central server (the common case — your
    team likely has one already running). You need its URL.
  - Stand up your own with [junto-stack](https://github.com/tlemmons/junto-stack).
- **Claude CLI installed** (`claude --version` works) — the
  `--append-system-prompt-file` flag is the delivery mechanism for the
  umbrella's template.
- **A shell** (bash 3.2+ on macOS, bash 4+ or any POSIX shell on Linux,
  PowerShell 5.1+ on Windows). The umbrella's renderer scripts target
  these.
- **`git`** — for cloning the umbrella repo and any per-project overlays.

You may need (depending on the deployment):

- **An API key** for the memory server if it has `MCP_AUTH_ENABLED=true`.
  Get this from whoever runs the server. The base template accepts an
  optional `{{api_key}}` for this.

What you do **not** need for first-time setup:

- Docker (the agent runtime is native; only the *server* runs in Docker).
- A peer deployment (the simple-first-time path connects directly to the
  shared central server).
- The inbox plugin (opt-in; agents work without it).

---

## Path A — direct connect (the primary first-time path)

This is what most adopters want. Your agent on your laptop connects to a
shared central junto-memory server. No local peer, no Docker on your
machine, no plugin needed for v0.

### A1. Verify the server is reachable

The MCP JSON-RPC endpoint is at `/mcp`, but the health probe is at root
`/health` (not under `/mcp`):

```sh
curl -sf http://your-server:8080/health
```

If you get `{"status":"healthy",...}`, you're wired up. If not, fix
network reachability before continuing — the rest of this doc assumes the
link works. If the server uses Tailscale/VPN routing, see the
[tailnet troubleshooting note](https://github.com/tlemmons/junto-memory/blob/main/docs/workjunto-pilot-setup.md#step-3--join-the-peer-vm-to-tailscale)
in the peer-deployment doc — the diagnostic patterns generalize.

### A2. Register the server as an MCP server

Wherever your MCP client configuration lives (`~/.mcp.json`, Claude Code
project `.mcp.json`, or per-project `mcpServers` in `claude.json`), add a
`junto` entry. Use the full `/mcp` path on the URL — the JSON-RPC
endpoint lives there:

```json
{
  "mcpServers": {
    "junto": {
      "type": "http",
      "url": "http://your-server:8080/mcp"
    }
  }
}
```

(Claude Code adopters can omit the `type` field — `url` alone is enough;
the field is required by other MCP clients that support multiple
transports.)

If the server requires auth, add the API key per your MCP client's
documented mechanism (typically a header or env var; varies by client).

### A3. Clone the umbrella repo

Pick any local path — the renderer scripts use relative paths, so the
directory name doesn't matter.

```sh
git clone https://github.com/tlemmons/junto.git ~/.junto
```

(See [templates/README.md → Vendoring vs fetching](../templates/README.md#vendoring-vs-fetching)
for alternatives if you want to vendor a frozen sha into your launcher
repo instead.)

### A4. Render your agent's system prompt

The base template is parameterized. For a single agent in project
`myproject` with role "primary engineer", running from `~/work/myproject`:

```sh
cd ~/.junto/templates

./render.sh \
    --agent main \
    --project myproject \
    --role "primary engineer" \
    --shared-memory-url "http://your-server:8080/mcp" \
    --cwd "$HOME/work/myproject" \
    --out /tmp/myproject-main-prompt.md
```

Add `--api-key "$JUNTO_API_KEY"` if the server has auth on. Add
`--plugin-present true` if you intend to launch with the junto-inbox
plugin (more in [Layer 3](#layer-3---live-message-delivery-optional)
below). See [templates/README.md](../templates/README.md) for the full
variable surface and overlay/extras layers.

### A5. Launch the agent with the rendered prompt

```sh
cd ~/work/myproject
claude --append-system-prompt-file /tmp/myproject-main-prompt.md
```

(Wrap A4 + A5 into a shell function or launcher script for repeat use.)

### A6. Smoke test

In the agent's first turn, ask:

> what is your name, project, and the contract you follow at session
> start?

The agent should respond with the identity you passed (`main@myproject`),
its role description, and reference `memory_start_session` as the
mandatory first call. If it says "I am Claude" or asks you to pick a
name, the template didn't apply — check the file you passed to
`--append-system-prompt-file`, and check for identity-assignment rules
in `~/.claude/CLAUDE.md` that may be racing the template (see
[templates/README.md → Adopter checklist step 3](../templates/README.md#adopter-checklist)).

The agent should then call `memory_start_session(project="myproject",
claude_instance="main", role_description="...")` as its first MCP call.
If it does, the wiring is correct end-to-end.

---

## Do I need a peer?

**Short answer: probably not, at first.** Direct connect (Path A) is the
simple-first-time path and what most adopters should start with.

Reach for a local peer when:

- You need writes to keep flowing during network outages between your
  laptop and the central server (the peer accumulates locally and
  replicates when the link returns).
- You're remote and your connectivity to the central server is
  intermittent (home network, hotel/cafe wifi, mobile tether).
- You're testing the system's resilience properties on purpose.
- Your team is running 3+ agents off the same network link and the round
  trip to the central server is a measurable bottleneck.

For everything else — single-laptop adopter, casual use, demo, workshop
— direct connect (Path A) is what you want.

If you do need a peer, the canonical deployment guide lives in
**junto-memory**, not in this umbrella:
[junto-memory/docs/workjunto-pilot-setup.md](https://github.com/tlemmons/junto-memory/blob/main/docs/workjunto-pilot-setup.md).
It walks from a fresh Hyper-V VM through bootstrap + Tailscale + sync-engine
verification. Once your peer is up, the rest of this guide (A2-A6 above)
still applies — you just point `--shared-memory-url` at the peer's local
URL (`http://<peer-vm-lan-ip>:8080/mcp`) instead of the central server.

---

## Layer 3 — live message delivery (optional)

The inbox plugin is a Claude Code channel plugin that delivers
peer-to-peer messages as `<channel>` blocks in the agent's next turn.
Without it, agents only see messages when they explicitly call
`memory_get_messages` (or on `memory_start_session` for queued ones).

**You want the plugin when:**

- You have multiple junto agents coordinating across projects or repos.
- You're running an agent that needs to react quickly to peer messages
  (a coordinator, a CI gate, a watchdog).
- You're demoing or workshopping the system and want the messaging story
  visible.

**You don't need it when:**

- You're a solo agent in a single repo with no peers.
- You only consume messages on session start (`memory_start_session`
  returns recent ones).
- You're new to junto and want one fewer moving piece while you learn the
  basics.

To install (Claude Code 2.1+):

```text
/plugin install junto-inbox@tlemmons-junto-inbox
```

Then launch your agent with the channel arg:

```sh
claude --append-system-prompt-file /tmp/myproject-main-prompt.md \
       --channels plugin:junto-inbox@tlemmons-junto-inbox
```

And re-render the template with `--plugin-present true` so the base
template injects the "plugin session ≠ agent session" clarifier block.

See the [junto-inbox README](https://github.com/tlemmons/junto-inbox) for
the plugin's own setup details, marker semantics, and known gotchas.

**Corporate Claude Code deployments — managed-settings gotcha.** If your
Claude Code install pulls a managed-settings policy file
(`/etc/claude-code/managed-settings.json` on Linux/macOS, or via
`CLAUDE_CODE_REMOTE_SETTINGS_PATH`), then `channelsEnabled` **and**
`allowedChannelPlugins` must be present at that policy tier — not just
in your user settings. A user-tier override does not unblock a
policy-tier allowlist gap. Symptom at launch: `not on the approved
channels allowlist`. Fix: edit the policy file directly (or point
`CLAUDE_CODE_REMOTE_SETTINGS_PATH` at a file you control) to include
both fields. This bit the workJunto pilot for a full session before the
policy-tier distinction was found.

---

## After the first agent works

Once Path A produces a session where the agent introduces itself and
calls `memory_start_session` correctly, you have a working junto setup.
Realistic next steps:

1. **Migrate your project's `CLAUDE.md`.** Most repos accumulate
   operational rules (park checklists, peer routing, marker handling)
   that now live in the template. Thin `CLAUDE.md` to repo orientation
   only and add the line:
   > Source of truth for system rules: tlemmons/junto/templates/junto-system-prompt.md.tmpl

   See [docs/claude-md-migration.md](./claude-md-migration.md) for an
   annotated before/after example.

2. **Consider an overlay.** If your project has rules that apply to its
   agents but don't generalize across all junto projects (team roster,
   project-specific escalation, non-default tooling), add an overlay
   file. See [templates/README.md → Project overlay](../templates/README.md#project-overlay-optional)
   for when this is worth doing (and when it isn't).

3. **Wire more agents.** Each additional agent gets its own
   `claude_instance` and (optionally) its own overlay/extras layer.
   Single-launcher-per-agent is the common pattern.

4. **Hook up the dashboard** (optional). [junto-control](https://github.com/tlemmons/junto-control)
   is the human-facing dashboard for monitoring agent activity, sending
   messages from a human, and reviewing destructive-keyword-gated
   messages. Useful once you have 3+ agents to track.

5. **Read the wire conventions.** The template body assumes specific
   junto-memory shapes — state spec naming (`state:<agent>`), system
   sender identity (`system@<project>`), marker strings. See
   [templates/README.md → Wire conventions](../templates/README.md#wire-conventions-template-baked).

---

## Common first-day surprises

- **The template is mandatory, the overlay is optional.** Resist the
  urge to add an overlay on day one. Most projects work fine with the
  base alone.
- **`memory_start_session` is the first MCP call, every session, no
  exceptions.** The template's park checklist and identity model both
  depend on this. If you find yourself wanting to skip it, you've
  probably misread the rule.
- **`CLAUDE.md` is for repo orientation, not operational rules.** Any
  rule that applies to "every junto agent" goes in the template, not
  `CLAUDE.md`. Any rule that's "how this specific repo is laid out"
  stays in `CLAUDE.md`.
- **A global `~/.claude/CLAUDE.md` with identity-assignment rules can
  race the template.** If smoke test A6 doesn't return your agent's
  rendered identity, audit your global config (see
  [templates/README.md → Adopter checklist step 3](../templates/README.md#adopter-checklist)).
- **The agent runs natively; the server runs in Docker.** If you're
  doing a peer deployment, the peer's memory stack (mongo + chroma +
  mcp-server + sync-engine) runs in Docker on a peer VM. The agent
  process is `claude` on your laptop host, not inside any container.

---

## Getting help

- **Open an issue** at <https://github.com/tlemmons/junto> for
  umbrella/template feedback, or against the specific component repo
  (junto-memory, junto-inbox, junto-control) for component-specific
  issues.
- **File a backlog item** if you want it triaged by the junto agents
  themselves: from any session connected to junto-memory, call
  `memory_add_backlog_item(project="junto", title="...", description="...")`.
- **Time-sensitive contact** — tom@lemmons.net out-of-band.

The umbrella is intentionally small. If something here seems
underspecified for your setup, the answer probably lives in the
linked-to component repo — that's by design.
