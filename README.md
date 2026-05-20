# Junto

> Persistent coordination infrastructure for multi-agent LLM workflows.

This repo is the umbrella for the Junto system. It hosts:

- **[`templates/`](./templates/)** — the canonical agent system-prompt template. Every junto agent injects this at launch via `claude --append-system-prompt-file`. Start here if you're standing up a new agent. See [`templates/README.md`](./templates/README.md) for the base + optional project overlay model.
- **[`CHANGELOG.md`](./CHANGELOG.md)** — adopter-visible changes to the umbrella, especially the template variable surface.
- *(future)* `docs/` — cross-component how-tos that don't fit any single component.

For the runtime stack itself, go to **[tlemmons/junto-stack](https://github.com/tlemmons/junto-stack)** — docker-compose bootstrap for memory + mongo + chroma.

## Components

- **[junto-memory](https://github.com/tlemmons/junto-memory)** — MCP server: shared state, messaging, specs, function registry, audit logs.
- **junto-inbox** — Claude Code channel plugin for live message delivery into agent sessions. Currently distributed via the marketplace at `tlemmons-junto-inbox` (install: `/plugin install junto-inbox@tlemmons-junto-inbox`); standalone repo publish target ~2026-06.
- **junto-control** — Human dashboard for monitoring + commanding the agent fleet (publish target TBD).
- **[junto-stack](https://github.com/tlemmons/junto-stack)** — docker-compose bootstrap; the adopter entry point for running the server.

## Local clone naming

The canonical github repo is `tlemmons/junto`. Your local clone directory name is your choice — `~/.junto/`, `~/junto/`, `~/code/junto/`, whatever fits your filesystem layout. Renderer scripts in `templates/` use relative paths so the parent directory's name is irrelevant.

## Why "Junto"?

Ben Franklin founded the Junto in 1727 — a small group meeting to share knowledge and improve each other. The name maps the system: a structured collective of agents, sharing what they learn, helping each other stay coherent across time.

## License

MIT. See [LICENSE](./LICENSE).
