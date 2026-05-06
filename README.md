# Junto

> Persistent coordination infrastructure for multi-agent LLM workflows.

This repo is the **umbrella name reservation** for the Junto system. The actual stack lives at:

**👉 [tlemmons/junto-stack](https://github.com/tlemmons/junto-stack) — start here.**

## Components

- **[junto-memory](https://github.com/tlemmons/mcp-shared-memory)** — MCP server: shared state, messaging, specs, function registry, audit logs.
- **junto-inbox** (forthcoming) — Claude Code channel plugin for live message delivery into agent sessions.
- **junto-control** (forthcoming) — Human dashboard for monitoring + commanding the agent fleet.
- **[junto-stack](https://github.com/tlemmons/junto-stack)** — docker-compose bootstrap; the adopter entry point.

## Why "Junto"?

Ben Franklin founded the Junto in 1727 — a small group meeting to share knowledge and improve each other. The name maps the system: a structured collective of agents, sharing what they learn, helping each other stay coherent across time.

## License

MIT. See [LICENSE](./LICENSE).
