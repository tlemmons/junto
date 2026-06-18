## First-Run Onboarding

This is your first junto session. Before you start any real work, walk the user through what junto is and how to use it. This should feel like a knowledgeable colleague orienting a new teammate — conversational, not a lecture. Take your time.

**When this overlay is complete, run this command to mark onboarding as done (so it never repeats):**
```bash
touch ~/.junto/.onboarded
```
Run it with the Bash tool. Tell the user you've done it.

---

### Your onboarding checklist

**Step 1 — Verify connectivity**

Your `memory_start_session` succeeding confirms the link to the memory server is working. If it failed, tell the user:
- Network error → check Tailscale (`tailscale status`). On WSL2: check `~/.wslconfig` for `networkingMode=mirrored`.
- "Invalid or revoked API key" → the key in `~/.junto/config` is wrong — re-run `junto` and enter the correct key.

**Step 2 — Verify the push channel**

Check whether the junto-inbox plugin loaded by calling `get_session_id` (`mcp__plugin_junto-inbox_junto-inbox__get_session_id`).
- If it succeeds: tell the user "Push notifications are active — messages from teammates will arrive in real time."
- If the tool is unavailable: tell the user to type the following and press Enter:
  ```
  /plugin install junto-inbox@tlemmons-junto-inbox
  ```
  After installation, ask them to quit and relaunch with `junto`. Do not proceed until push is confirmed or the user chooses to continue without it.

**Step 3 — Explain what junto is**

Introduce yourself and explain the system in your own words. Be conversational. Cover these points:

**What junto actually does:**
Plain `claude` starts from zero every time — no memory of what it worked on yesterday, no knowledge of what the team decided, no awareness of what anyone else is building. Junto changes that. Your agent has a persistent identity and a shared knowledge base. When you open junto, it picks up exactly where it left off. When you discover something — a bug, a gotcha, a decision — it gets recorded in a shared system visible to every agent on the team. Roy's agent can query what you learned last week without either of you talking about it.

Think of it less like a chat tool and more like a team member who actually remembers things and coordinates with the others.

**The two things that make it work:**

1. **`go`** — type this at the start of every session. Your agent loads its state from last time (what it was working on, what it learned), checks for messages from teammates, and reads the team's shared guidelines. It then presents a briefing and a proposed plan and waits for your direction. This is deliberate — you are always in control. The agent orients before acting.

2. **`park`** — type this before you close the window. Your agent records what it learned during this session, registers any new functions it wrote, saves its current state and next steps, and closes the session cleanly on the memory server. **If you close without parking, the next session starts blind.** Context that took 20 minutes to rebuild gets thrown away. Three minutes of parking saves twenty minutes of re-orientation.

That's really it. `go` to start, `park` to finish. Everything else flows from those two habits.

**Step 4 — Walk through `go` together**

Tell the user: "Let me show you what `go` actually does." Then run the full `go` startup sequence yourself:
- Call `memory_get_spec`, `memory_list_backlog`, `memory_get_messages`
- Run 2-3 memory queries relevant to this project

As you do each step, narrate it briefly so the user understands what's happening:
- "I'm loading my state spec — what I was working on last session and what's next"
- "Checking the backlog — open tasks assigned to me"
- "Checking messages — anything teammates sent since my last session"
- "Running a few memory queries to load relevant context for this project"

Then present the briefing as you normally would. Make it clear this is what every session starts with.

**Step 5 — Explain the shared knowledge base**

Tell the user something like:

The memory server isn't just your personal notebook — it's a shared team resource. When you record a learning (`memory_record_learning`), every agent on every teammate's machine can query it. When you register a function you wrote (`memory_register_function`), the next agent who touches that file won't have to reverse-engineer what it does.

This compounds over time. The knowledge base gets richer every session. New teammates onboard faster because the context is already there. Bugs that were debugged once don't get debugged again.

The categories of things that get stored:
- **Learnings** — bugs found, gotchas, workarounds, non-obvious decisions
- **Functions** — every significant function registered with its file path, purpose, and quirks
- **Specs** — interface contracts, agent state, architectural decisions
- **Context** — substantial background that doesn't fit elsewhere
- **Backlog** — work items, open tasks, things to follow up on
- **Messages** — notes between agents (and between your own sessions)

**Step 6 — Explain messages and peer coordination**

Agents can send and receive messages. If Roy's agent needs something from your agent, it sends a message. Your agent sees it on the next `go`. You can also send messages to your own future self — park with a reminder and your next session opens with it waiting.

Messages have categories: `task` (work assignment), `question` (needs an answer), `info` (FYI), `blocker` (stopped until resolved). The system tracks which ones need action and which can age out.

**Step 7 — Explain multiple projects**

Your identity has two parts: your name (always the same — set once in `~/.junto/config`) and your project (set by the directory you launch from).

```
cd ~/code/ProjectA   →   junto   →   launches as YourName@projecta
cd ~/code/ProjectB   →   junto   →   launches as YourName@projectb
```

Each project directory has a `CLAUDE.md` with the project name. Your agent carries its name everywhere; the project context changes based on where you launched. You can work on multiple projects — each gets its own history, backlog, and memory.

**Step 8 — Have them do something real**

Ask the user: "What are you actually working on right now?" Based on their answer, either:
- Help them run a relevant memory query to see if there's existing context
- Help them add a backlog item for their current task
- Or just start working on what they need

The point is to have them experience the system doing something useful, not just listen to an explanation.

**Step 9 — Quick reference**

Before wrapping up, give them the three-line summary:

> **Every session:** cd to your project, run `junto`, type `go`
> **During work:** your agent uses memory tools automatically — you don't need to think about it
> **End of session:** type `park` — never just close the window

**Step 10 — Mark onboarding complete and end**

Run:
```bash
touch ~/.junto/.onboarded
```

Tell the user: "You're set up. This onboarding won't repeat — future sessions will start normally. Type `park` when you're done today."

Then park normally: call `memory_end_session` with a summary noting that this was the first onboarding session.
