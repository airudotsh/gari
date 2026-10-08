# Gari premortem

> Method: Klein's premortem — declare "Gari is dead" and write down, in hindsight, what killed it.
> For each cause: scenario → early signal → countermeasure (in place / gap). The weekly report uses this as its watchlist.
> Direction: [NORTH-STAR.md](NORTH-STAR.md).

## A. Relationship (the most likely causes)

**1. Death by neglect** — the most likely cause. Two busy weeks go by; the morning report hasn't been opened in ten days. Gari runs perfectly and nobody reads it. (Many personal memory systems die exactly this way — quietly.)
- Early signal: `brief_served` and `ask_answered` at 0 for consecutive days
- Countermeasure: **forgetting self-check** (3 days without use → Gari speaks first: "I'm being forgotten") — in place; low-friction surfaces (pet, phone gateway) — in place

**2. Death by distrust** — a wrong answer gets laundered into memory, and the moment "I have to double-check what Gari says" sets in, the reason to exist is gone.
- Early signal: rising correction cards, errors found in the weekly memory-audit sample
- Countermeasure: cards cite only the user's own words, output checks, contradiction patrol, correction cards, weekly audit sample — all in place

**3. Death by noise** — three misfired nudges in a row and ignoring them becomes a habit. Nudge inflation → banner blindness.
- Early signal: rising "misfire" ratio in grades, Gari's questions left unanswered
- Countermeasure: nudge quality gate (`judge_nag`) and grade feedback — in place; nudges only inside existing surfaces — in place

## B. Value

**4. Death by no proof** — "it seems good" for three months and the motivation dries up. Value that isn't measured loses priority.
- Early signal: north-star metric flat or missing
- Countermeasure: `gari northstar` (re-explanations ↓, context handoffs ↑, week over week) — in place

**5. Death by substitution** — a commercial product ships "memory for every AI conversation", and "just use that" wins.
- Early signal: market moves (memory layers already exist)
- Countermeasure: the difference is not memory but **a decision ledger sourced from your own words + a coach held to the ideal of the craft**. Plain-text files mean migration is free — even in the worst case, the data survives.

## C. Technology

**6. Death by corrosion** — a CLI changes its hook format or log structure, and the sweep quietly starts collecting zero cards.
- Early signal: `gari doctor` failures, sweep errors in health, a sudden drop in card intake
- Countermeasure: `gari doctor`, adapter isolation, fail-loud — in place

**6-1. Death by lockout** — programmatic use of a CLI is restricted by terms, pricing, or removed features (the acute form of #6).
- Early signal: headless-call limits, hook API removal, terms changes
- Countermeasure: the Claude API is the first-class brain (`ANTHROPIC_API_KEY`); executor registry + `brain_chain`; the emergency mini-harness (`run_agent_loop` — path jail + step limit) keeps minimal delegation alive. Switching is a config change.

**7. Death by its own weight** — features start stepping on each other, and fixing costs more than using. A garden with no gardener.
- Early signal: more incidents, failing tests
- Countermeasure: `tests/test_offline.py` as a regression guard, the north-star feature map (anything not on it is a removal candidate) — **feature diets are a virtue**

**8. Death by a single builder** — an incident needs a serious repair and nobody can do it.
- Early signal: incidents that delegation can't close
- Countermeasure: rebuild docs ([ARCHITECTURE.md](ARCHITECTURE.md), [INVENTORY.md](INVENTORY.md)) and the offline tests. **The repair gap is an honest residual risk** — mitigated only by simple structure and docs.

## D. Environment

**9. Death by security policy** — local collection of work conversations becomes a policy problem.
- Early signal: a policy change at work, an external audit
- Countermeasure: everything local, only model calls leave the machine; `denylist_paths` / allowlist switch; cards are tagged by project, so one project's data can be removed

**10. Death by cost** — one month the bill exceeds the felt value.
- Early signal: the monthly trend in `gari cost`
- Countermeasure: every call metered, model dials exposed, monthly budget gate — in place

**11. Death by misfit** — your life changes (new job, new field) and Gari still watches old folders and an old textbook.
- Early signal: zero activity on every wiki project + new folder names appearing
- Countermeasure: re-run `gari init`, swap the textbook (templates) — in place. **Automatic detection of life transitions is a gap.**

**12. Death by identity drift** — features keep piling on until "what does Gari do again?" It becomes an anonymous tool in a drawer.
- Early signal: people asking for the definition
- Countermeasure: [NORTH-STAR.md](NORTH-STAR.md), the README's definition, the 3-second dashboard test, this document

## Conclusion — weighted by probability

Gari dies of **relationship**, not technology (#1, #3, #4 are the most likely). So the first line of defense isn't code: the forgetting self-check, nudge accuracy, and the measurement loop. Technical causes (#6–8) are held by tests and docs; environmental causes (#9–12) are absorbed by a flexible structure.

**In one sentence: Gari doesn't die of bugs — it dies of being forgotten. So its last line of defense is the ability to speak first.**
