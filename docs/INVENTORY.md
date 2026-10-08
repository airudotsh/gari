# Gari inventory — what gets installed, and what it can do

> What "installing Gari" means, exactly. Direction: [NORTH-STAR.md](NORTH-STAR.md).

## 1. What gets installed (footprint ~1 MB, no server, no daemon)

| Location | What | Notes |
|---|---|---|
| Gari's home (this repo, default `~/gari`) | Engine (`gari.py`), config (`config.json`), secrets (`secrets.env`, mode 600), prompts (`templates/`), **data** (`store/`, `works/`, `reports/`) | One folder is Gari. Delete it and Gari is gone |
| `~/.local/bin/gari` | Terminal command (symlink) | |
| `~/Library/LaunchAgents/com.airu.gari-*.plist` ×4 | Schedules: sweep (every 10 min), morning (report hour), weekly (Mon 09:30), pet (at login) | macOS scheduler — nothing stays resident |
| `/Applications/Gari.app` | Pet app shell (Spotlight "Gari" wakes it) | A copy of `pet/gari-pet` |
| Claude Code `settings.json` — 2 hooks | SessionStart (briefing) · Stop (collection signal) | **Added** to existing settings, with a backup |
| Codex `hooks.json` — 1 hook | Stop signal | Only if Codex is installed |

**Read-only (never modified):** `~/.claude/projects/`, `~/.codex/sessions/`, `~/.gjc/agent/sessions/`. Gari keeps cursors (how far it has read), never copies.

**What leaves the machine:** only model calls — to the Claude API with your own key (or through Claude Code). No Gari server.

## 2. What it can do

### Automatically
- **Collect & distill** every 10 min: CLI conversations → cards (decision, pending, correction, win), grouped by project
- **Morning report**: yesterday's summary, today's one step, Gari's question, a nudge, watchlist, sign-off box
- **Weekly report** (Mon 09:30): trends, the re-explanation metric, corrections
- **Session briefing**: recent decisions and pendings at session start (or on demand with `gari brief`)
- **Dashboard** (`gari dash`, 127.0.0.1 only): inbox, today's cards, automation history, log, chat, sign-off/merge buttons
- **Pet**: quick chat + honest mood (idle = asleep, working = bubbles, problem = belly-up)
- **Measured pulse**: git activity in project folders — code work never mentioned in chat still shows up
- **Worktree isolation**: write-delegations to your repos run in an isolated copy; merging is `gari merge`
- **Brain registry**: Claude (API or Claude Code) first; optional extra API brains via `executors`, with a fallback chain
- **Staged projects**: a plan with a dependency graph — ready stages run in parallel (max 3), real-output verification per stage, replan on findings
- **Skills**: method notes in `store/skills/` attached when a trigger matches
- **Schedules**: "every morning, check …" + "go" registers a recurring task
- **Event gate**: `gari event "…"` lets external scripts push events
- **Telegram gateway** (off until a bot token is set)
- **Nudge quality gate**: each nudge is judged before it's shown; misses are pulled; your grades become examples

### When you ask (`gari ask`, or the pet's chat tab)
- **Memory**: "what did I decide yesterday?" → answer from cards, with source
- **Documents**: if the cards are empty, local docs are searched
- **General & current questions**: with web search
- **Planning & judgment**: deep answers grounded in 11 methodology sources
- **Nudges**: at the end of answers, the thing you're missing
- **Standing instructions**: "from now on, …" is saved and applied to everything after

### When you delegate (say "do …" in chat → "go")
- Gari packages context and hands it to a worker AI (Claude Code / Codex / gjc) in the background → result saved + card + notification
- Big jobs become staged projects with a plan you approve; each stage is verified against the repo, not the report; two failed checks → it stops and asks you

### All commands
`gari` (report) · `ask` · `do` · `project` · `pulse` · `triage` · `snooze` · `chat` · `hud` · `grade` · `resolve` · `log` · `brief` · `done` · `status` · `cost` · `weekly` · `northstar` · `doctor` · `init` · `pet` · `dash` · `cron` · `skill` · `event` · `merge` · `wiki` · `backfill`

## 3. First run

```
Needs: macOS + a Claude API key (console.anthropic.com). Claude Code is optional (needed for `gari do` and document search).
  ↓
./install.sh      prerequisites → command → pet build → gari init
  ↓
gari init         name, form of address, collection folders, report hour (≈10 s)
                  → hooks + schedules registered → gari doctor
  ↓
Done. Keep working as usual — first morning report on day 2.
```

- **`gari doctor`**: start here when something feels off — API key, live call, schedules, hooks, last sweep.
- **`gari init`** is safe to re-run.
- If the brain is unreachable: collection, pet, and the log keep working; distillation, chat, and reports pause with a clear message.

## 4. Cold start

| When | What works |
|---|---|
| Right after install | General questions, deep judgment, nudges, delegation |
| Half a day | Memory questions — the first cards |
| Day 2 | First morning report |
| Week 1 | Personalized nudges (from your pendings and corrections) |
| Week 2+ | Shadow-coach calls, once enough grades exist |

"Today's one step" and direction nudges work best with a direction document — set `north_star_path` in config.

## 5. Uninstall

`launchctl unload ~/Library/LaunchAgents/com.airu.gari-*.plist` → delete Gari's home and `/Applications/Gari.app` → remove the Gari hooks from `~/.claude/settings.json` and `~/.codex/hooks.json`. **Your original conversations were never inside Gari, so nothing is lost.**
