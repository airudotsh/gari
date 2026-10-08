# Gari 🐠

> **An agent for vibe coders — remembers, briefs, and meddles.**

<p align="center">
  <img src="docs/img/gari-pet.png" width="120" alt="Gari, the pixel fish pet">
  <img src="docs/img/gari-chat.png" width="300" alt="Gari's chat panel">
</p>

When you work with several AI coding CLIs in parallel (Claude Code, Codex, …), real decisions get made *inside conversations* — and vanish when the session ends. The next session starts from zero, and you explain everything again.

Gari sits between those conversations. It reads them, keeps a ledger of **your decisions, open questions, and corrections** — sourced only from your own words — briefs you when you need it, and points out what you're missing.

**North star: zero re-explaining.** Context you gave once should never have to be given again. → [docs/NORTH-STAR.md](docs/NORTH-STAR.md)

## What it does

| Layer | What happens |
|---|---|
| **Remember** | Every 10 minutes, new CLI conversations → cards (decision · pending · correction · win) → a current-state wiki per project |
| **Brief** | `gari brief` (or the session-start hook) gives recent decisions and open items — no re-explaining |
| **Morning sign-off** | Each morning: today's one step, a mentor review, open items, things waiting for your OK |
| **Ask** | Click the pet or run `gari ask` — memory answers in seconds, deep planning discussions, web search |
| **Delegate** | Say "do …", approve with "go" → Gari hands it to a worker AI in an isolated branch, verifies the real output, reports back |
| **Meddle** | Design-thinking and PM lenses catch what you're missing — every nudge is quality-gated before you see it |

`gari northstar` shows whether it's working: re-explanations should go down, context handoffs should go up.

## Built on Claude

Gari's brain is the **Claude API**. Put your key in `secrets.env` and every text-only step — distilling conversations, answering from memory, judging nudges, writing wikis, the morning review — goes straight to the Messages API. Model aliases (`haiku`, `sonnet`, `opus`) resolve to the newest matching model automatically.

Steps that need tools (reading your repo, web search, delegated coding) run through [Claude Code](https://claude.com/claude-code), which uses the same key. Every call is metered in `store/usage.jsonl`; `gari cost` shows the spend.

## Install

Requirements: macOS, Python 3, Xcode Command Line Tools, a Claude API key from [console.anthropic.com](https://console.anthropic.com/). Claude Code is optional (needed for `gari do` and document search).

```sh
git clone https://github.com/airudotsh/gari.git ~/gari
cd ~/gari && ./install.sh
```

The installer creates `config.json` and `secrets.env` (mode 600), builds the pet, and runs `gari init` (name, form of address, folders, report hour). Then add your key:

```sh
echo 'ANTHROPIC_API_KEY=sk-ant-...' >> ~/gari/secrets.env
gari doctor
```

Keep working as usual. Memory answers start within half a day; the first morning report arrives on day two.

## Commands

`gari` (latest report) · `ask` · `do` · `brief` · `northstar` · `status` · `doctor` · `init` · `log` · `resolve` · `snooze` · `triage` · `grade` · `chat` · `weekly` · `cost` · `pulse` · `wiki` · `project` · `merge` · `cron` · `skill` · `event` · `dash` · `pet` · `backfill`

## Privacy

- Everything lives in one folder (Gari's home). No server, no daemon, no telemetry.
- Original conversations stay in each CLI's own folder; Gari only reads them and remembers how far it has read.
- The only data that leaves your Mac is model calls — to the Claude API, with your key.
- `allowlist_paths` / `denylist_paths` in `config.json` decide which projects are collected.

## Docs

- [NORTH-STAR.md](docs/NORTH-STAR.md) — the problem, the metric, the guardrails
- [INVENTORY.md](docs/INVENTORY.md) — what gets installed and what it can do
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — where to change what
- [premortem.md](docs/premortem.md) — how Gari could die, and the defenses

## Status

Early. Used daily by its author since July 2026. Offline tests: `python3 tests/test_offline.py`.

## License

MIT — see [LICENSE](LICENSE).
Pet sprite: "Cute Fish Sprites" by **chips8688** ([OpenGameArt](https://opengameart.org/content/cute-fish-sprites)), OGA-BY 3.0, modified (colors/composition). The artwork is not covered by the MIT license.
