# Gari — Problem & North Star

> Every feature, hook, and prompt in this repo must trace back to this page.
> If it doesn't move the north star or protect a guardrail, it gets cut.

## The problem

Builders who work with several AI coding CLIs in parallel (Claude Code, Codex, …)
make real decisions *inside conversations* — "let's do X", "no, not like that",
"wait on Y until Z". Those decisions vanish when the session ends.

What that costs, every day:

1. **Re-explaining.** Each new session starts from zero. You retype the same
   context, constraints, and past decisions.
2. **Lost loose ends.** Things that were discussed but not decided quietly
   disappear. Nobody follows up.
3. **Repeated corrections.** You correct the AI the same way you did last week,
   because the correction lived in a transcript nobody reads.
4. **Drift from your own standards.** "Ship without verifying" happens in a rush,
   and nothing notices.

Existing memory products store *facts about you*. Gari keeps a ledger of
*your decisions* — sourced from your own words, per project, across tools.

## Who it's for

A solo builder or a very small team running multiple AI CLIs on one Mac,
who wants continuity without adopting a new workspace.

## North star

**Zero re-explaining.** Context you already gave once should never have to be
given again — in any tool, any session, any project.

### Measured as

| Metric | Source | Direction |
|---|---|---|
| **Re-explanations per week** — `repeat` cards (the same instruction or context given again) | distilled ledger | ↓ |
| **Context handoffs** — times a briefing or a memory answer replaced a re-explanation (`brief_served` + `ask_answered`) | `store/metrics.jsonl` | ↑ |

`gari northstar` prints both for the last 7 days against the previous 7.

### Guardrails (things that kill Gari if they go wrong)

| Guardrail | Why | Signal |
|---|---|---|
| **Trust** — cards cite only what the user actually said | One laundered wrong answer and every answer must be double-checked | rising `correction` cards about Gari itself |
| **Not forgotten** — Gari speaks first when ignored | The most likely death is silent neglect (see `premortem.md`) | 3 days with zero handoffs → Gari nudges |
| **Not noisy** — nudges must be graded and earn their place | Ignored nudges train the user to ignore Gari | "misfire" ratio in `gari grade` |
| **Local & owned** — plain files, no daemon, no upload except model calls | The ledger is the user's asset, portable forever | `gari doctor` |
| **Cost** — every model call is metered | Value must exceed the bill | `gari cost` |

## Feature map

| Feature | Serves |
|---|---|
| Sweep + distill (CLI transcripts → decision/pending/correction cards) | the ledger everything else reads |
| `gari brief` (pull-only briefing) | zero re-explaining at session start |
| `gari ask` (memory answers, deep discussion) | zero re-explaining mid-session |
| Morning report (today's one step, open pendings, mentor review) | lost loose ends |
| Nudges (`«nudge —»`) | drift from your own standards |
| `gari do` (delegate in an isolated branch, verify, report) | follow-through on decisions |
| Project wiki | current state per project, without rereading transcripts |
| Desktop pet | low-friction surface so Gari isn't forgotten |

Anything not in this table is a candidate for removal.

## Non-goals

- Becoming another IDE, chat app, or team workspace.
- Auto-injecting Gari into other CLIs' prompts (other agents must not *become* Gari).
- Auto-merging or pushing code. Gari stops at an isolated branch.
- Collecting company or third-party data without an explicit allowlist.
