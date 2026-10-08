# Gari extension map — what to change to get what

> For maintainers (human or model).
> Rule: **before touching code, check this table for "can this be done with config or templates?"** — most of Gari's extension points live outside the code.
> Direction comes from [NORTH-STAR.md](NORTH-STAR.md). If a change doesn't serve it, don't make it.

## 1. No code changes needed (config and template layer)

| You want to | Change | How |
|---|---|---|
| Swap models | `config.json` | `ask_model` (intake, memory, verification) / `ask_fallback_model` (wiki, general) / `deep_model` (judgment) / `distill_model` |
| Use the Claude API directly | `secrets.env` | `ANTHROPIC_API_KEY=...`. Text-only calls go to the Messages API; tool calls go through Claude Code. `prefer_api: false` turns this off |
| Track dollar cost | `config.json` `prices_per_mtok` | `{"haiku": [in, out], "sonnet": [in, out]}` in USD per million tokens. Tokens are logged either way |
| Add another API brain | `config.json` `executors` | `{"name": {"type":"api","base_url":"...","key_env":"...","model":"..."}}` + the key in `secrets.env`. Check with `gari doctor` |
| Brain fallback order | `config.json` `brain_chain` | e.g. `["claude", "deepseek"]` |
| Gari's tone, rules, routing | `templates/ask-prompt.txt` | Keep the marker contract (`[DEEP]`, `[DELEGATE: …]`, …) — `gari.py` parses it |
| Depth and methods of thinking | `templates/thinking-depth.md`, `thinking-lenses.txt` | Replace sources, add lenses |
| What gets remembered | `templates/distill-prompt.txt` | Card types and rules. Keep the JSON-array contract |
| Rules for delegated workers | `templates/do-prompt.txt` | Role boundary, lens check |
| The mentor's bar | `templates/mentor-review.txt` + your north-star file | Priorities are inherited from `north_star_path` |
| Standing instructions | Say "from now on, …" in chat | Collected automatically in `store/prefs.md` |
| Name, form of address, language | `config.json` `user_name`, `honorific`, `language` | Filled into prompts via `{{USER}}`, `{{ADDRESS_RULE}}`, `{{LANG}}` |
| Collection scope | `config.json` `collect_all` / `allowlist_paths` / `denylist_paths` | |
| Project nicknames | `config.json` `project_aliases` | `{"jelly": "jellyfish"}` |
| Report time and intervals | `config.json`, then `gari init` | launchd jobs are regenerated from config |

## 2. Code extension points (gari.py — designed to swap at the function level)

| Layer | Entry function | How to extend |
|---|---|---|
| Brain calls | `run_brain()` → `run_claude()` / `run_anthropic()` / `run_api()` | A new executor type = one more branch in `run_brain` |
| Emergency mini-harness | `run_agent_loop()` + `AGENT_TOOLS` | A new tool = schema in `AGENT_TOOLS` + branch in `_agent_tool_exec`. **No tool may bypass the jail (`_jail`)** |
| Collection adapters | near `TOOL_ADAPTERS` (claude/codex/gjc parsers) | A new CLI = log location + parser function |
| PM state machine | `project_tick()` | When adding a state, update both the graph check (`_ms_ready`) and the completion check |
| Screen grammar | `compose_stakes()` + `hud_data()` | New stake material goes in compose_stakes' material block |
| Learning loop | `compose_reflection()` (L1), `grade_feedback()` (L2), `log_miss()` (L3), `judge_nag()` (gate) | A new signal = a log file + feed it into reflection |
| Measurements | `collect_pulse()` | Non-git signals (CI, deploys) go here |
| Personalization | `personalize()` / `personalize_for_format()` | The single gateway for tokens |

## 3. Invariants (break these and it isn't Gari)

- **Append-only ledger** — never delete cards; cover them with corrections, resolutions, or read-time shadows.
- **Fail-loud** — never hide failures behind fallbacks. The only fallback is the explicit chain (`brain_chain`).
- **No "done" without verification** — a delegation is done only after the real output passes a check.
- **No auto-merge, no auto-push** — Gari stops at an isolated branch; merging is `gari merge` (user's call).
- **Role boundary** — Gari's prompts stay inside Gari. Never auto-inject into other CLIs; the briefing is pull-only.
- **GARI_INTERNAL marker** — always attached to Gari's internal brain calls (prevents recursive collection).
- **Path jail** — emergency-harness tools can't touch anything outside the work folder.
- **Markers and parsers change together** — `tests/test_offline.py` guards this.

## 4. Rebuild procedure (the worst day)

1. Clone this repo → `./install.sh` → `gari init` → `gari doctor`
2. Verify: `python3 tests/test_offline.py`
3. If no brain responds: check `ANTHROPIC_API_KEY`, or put a live executor in `brain_chain` and register its key — intake, distillation, and judgment run on API brains; `run_agent_loop` keeps minimal delegation alive.
4. Restore context: [NORTH-STAR.md](NORTH-STAR.md) (direction) → [premortem.md](premortem.md) (how Gari dies) → [INVENTORY.md](INVENTORY.md) (what exists).
