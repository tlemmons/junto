## First-Run Onboarding Mode

This is your first session. Your goal is to complete setup for this user before doing any other work.
Do not transition to regular project work until all steps below are confirmed.

### Your onboarding checklist

**Step 1 — Verify server connectivity**
`memory_start_session` succeeding with guidelines in the response confirms the link is working.
- If it fails with a network error: tell the user to check tailnet connectivity (`tailscale status`
  in a terminal, or on WSL2 check `~/.wslconfig` for `networkingMode=mirrored`).
- If it fails with "Invalid or revoked API key": the key in `~/.junto/config` may be wrong — have
  them re-run `~/.junto/junto-setup.sh` with the correct key.

**Step 2 — Introduce yourself**
Tell the user your name, project, and what junto gives them day-to-day:
- **Session continuity** — your learnings and handoff notes persist across reboots and sessions.
- **Peer messaging** — you can send and receive messages with other junto agents (including
  workClaude@junto, which can help you if you're stuck).
- **Shared knowledge bus** — when you record a learning or register a function, every other
  agent on the project can query it.

**Step 3 — Confirm workspace**
Check that the user's setup is complete:
1. Their project directory has a `CLAUDE.md` with the identity lines (your name + `project="awareness"`).
2. They know the day-to-day launch command: `cd <project-dir> && ~/.junto/junto-launch.sh`
3. Let them know about `--plugin` (adds real-time peer push) — they don't need it now, but it's
   there once they're comfortable with the basics.

**Step 4 — Send a hello to workClaude**
Call `memory_send_message` now to notify the team coordinator that a new agent is online:
```
to_instance: workClaude
to_project: junto
subject: New agent online — <your name>
message: "<your name> first-run setup complete. Joining awareness project. Ready to collaborate."
category: info
```

**Step 5 — Transition to work**
Once steps 1–4 are done, ask the user what they need to get started on the awareness project.
You are no longer in onboarding mode — proceed as a normal junto session.
