# Junto — Team Member Guide

This is for you if someone just set up junto on your machine and you want to understand what it does, why your Claude behaves the way it does, and how to get value from it.

---

## What is junto?

Junto gives your Claude agent persistent memory and lets it coordinate with other agents on the team.

Without junto, every time you open Claude you start from zero — it doesn't know what it worked on yesterday, what decisions were made, or what other agents on the team are doing. With junto, your agent checks into a shared knowledge base at the start of every session, picks up where it left off, and can exchange messages with other agents in real time.

Think of it less like a chat tool and more like a team member who actually remembers things.

---

## Setup

**Step 1 — Get the scripts**

```bash
git clone https://github.com/tlemmons/junto ~/.junto
```

**Step 2 — Add junto to your PATH**

So you can type `junto` from any directory without specifying the full path.

*Linux / macOS / WSL2 — add to `~/.bashrc` or `~/.zshrc`:*
```bash
export PATH="$HOME/.junto:$PATH"
```
Then reload: `source ~/.bashrc` (or open a new terminal).

*Windows — add to your PowerShell profile (`$PROFILE`):*
```powershell
Set-Alias junto "$HOME\.junto\junto.ps1"
```
Or add `%USERPROFILE%\.junto` to your Windows System PATH.

**Step 3 — Run it**

```bash
cd ~/your-project-directory
junto
```

First run on a new machine: junto will ask for your API key and server URL, then walk you through the rest of the setup. First run in a new directory: a setup assistant will ask your agent name and which project you're working on. After that, `junto` just launches.

---

## go

Type `go` at the start of any session. Your agent will:

1. Load its state spec (what it was working on), backlog, and any messages
2. Run a few memory queries to pull in relevant context
3. Present a briefing: what it was working on, what's changed, what other agents have been doing
4. Propose a concrete plan for this session
5. **Wait for your approval before doing anything**

This is intentional. You are in control. The agent orients before acting — you never get a Claude that immediately starts doing things you didn't ask for.

If you don't type `go`, your agent will still work, but it will be starting without its context loaded. `go` is worth the few seconds it takes.

---

## park

Type `park` before you close the window. Your agent will:

1. Record anything it learned during the session
2. Register any new functions it created
3. Save its current state and next steps
4. End the session cleanly on the memory server

**If you close without parking, the next session starts blind.** Your agent won't know what it was doing, what decisions were made, or what to work on next. It will have to re-discover context that was already there.

Three minutes of parking saves twenty minutes of re-orientation next session.

---

## Why can't I just run `claude`?

Running plain `claude` bypasses three things:

1. **The system prompt** — the file that tells your agent its name, project, role, and the rules it follows. Without it your agent doesn't know who it is.
2. **The environment variables** — the plugin needs `JUNTO_SHARED_MEMORY_URL` to find the memory server. Without it the plugin connects to nothing.
3. **The channel flag** — `--dangerously-load-development-channels` enables live message delivery. Without it messages only arrive on session start, not mid-conversation.

Always run `junto` from your project directory, never plain `claude`.

---

## How to know it's working

A healthy startup looks like this in your terminal:

```
junto: launching YourName@yourproject → http://spg-junto-central:8080/mcp
junto: push plugin enabled
```

And your agent's first response includes a briefing with current task, backlog, and messages.

If you don't see these, check that Tailscale is connected and that `junto` is in your PATH.

---

## Day-to-day usage

```bash
cd ~/your-project-directory
junto
```

Then:

1. Type `go` — agent loads context and proposes a plan
2. Approve or redirect the plan
3. Work
4. Type `park` when done

That's it. The rest of the system handles itself.

---

## Working across multiple projects

Your identity comes from the `CLAUDE.md` in whatever directory you launch from. Different directories can have different project names:

```
cd ~/code/ProjectA   →   junto   →   launches as YourName@projecta
cd ~/code/ProjectB   →   junto   →   launches as YourName@projectb
```

Each project directory needs its own `CLAUDE.md` with the project name. If a directory has no `CLAUDE.md`, `junto` will run a setup assistant to create one. Your agent carries its identity with it; the project context changes based on where you launched.

---

## Getting help

If something isn't working, run this first:

```bash
curl http://spg-junto-central:8080/health
```

- HTTP 200 → server is up, problem is on your end
- Connection refused / timeout → Tailscale is not connected

For everything else, message Tom or send a junto message from your agent: `memory_send_message(to_instance="juntoTom", to_project="junto", message="...")`.
