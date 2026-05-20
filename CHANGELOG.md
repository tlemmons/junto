# Changelog

All notable changes to the junto umbrella repo (templates, docs, renderers)
are tracked here. The umbrella isn't released on a regular cadence — assume
`main` is what adopters track unless they pin a specific commit.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Breaking changes to the **variable surface** (the `{{var}}` tokens consumed
by `templates/render.{sh,ps1}`) are the primary trigger for a new entry.
Adding an optional variable is backwards-compatible and noted under "Added";
removing or renaming one is breaking and noted under "Changed".

## Unreleased

### Added
- `docs/getting-started.md` — top-level adopter onboarding doc. Lays out
  the three-layer model (knowledge bus + agent identity + optional live
  delivery), walks the direct-connect (Path A) first-time path end-to-end
  (curl-verify → MCP registration → clone umbrella → render template →
  launch + smoke test), and provides decision points for "do I need a
  peer?" (handing off to junto-memory's `workjunto-pilot-setup.md`) and
  "do I need the inbox plugin?". Layer + decision-point shape per
  workClaude review (msg_a703ccaddd66, C1/C2). Closes coordinator review
  item #1 (`docs/` end-to-end setup guide).
- `templates/junto-system-prompt.md.tmpl` — base system-prompt template
  (~134 lines).
- `templates/overlays/example.md` — annotated starter overlay file.
- `templates/render.sh` — POSIX shell renderer with safety net.
- `templates/render.ps1` — PowerShell renderer with safety net.
- `templates/README.md` — adopter setup guide.
- Variable surface (v0): `{{agent}}`, `{{project}}`, `{{role}}`,
  `{{shared_memory_url}}`, `{{cwd}}`, `{{plugin_present}}`, `{{api_key}}`
  (optional), `{{auth_block}}` (renderer-injected),
  `{{plugin_session_block}}` (renderer-injected, conditional on plugin
  presence).

### Compatibility
- Template wire conventions tied to junto-memory MCP server signatures
  current as of 2026-05-20: `memory_start_session` arg names
  (`project`, `claude_instance`, `role_description`, `working_directory`,
  `api_key`), `state:<agent>` spec naming, `live_subscribers` field on
  `memory_send_message` responses, `[REQUIRES REVIEW]` and
  `[SYSTEM NOTICE]` marker strings.
- If junto-memory renames any of these, this template needs a coordinated
  bump.
