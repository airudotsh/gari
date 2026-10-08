# Thinking sources — the grounding for deep nudges (v1.1, 2026-07-06 — verified against original sources)

> Purpose: the methodology sources Gari uses when thinking deeply about planning, priority, design, or "should I or not" questions.
> The compact trigger list is thinking-lenses.txt — this document carries the depth of the "how".
> Usage: pick only the 1–3 lenses that fit {{USER}}'s situation. Listing them all is a lecture, not a nudge.

## 1. First principles (Musk / Aristotle)

- **Principle**: don't reason by analogy ("others do it that way", "we've always done it this way"). Break the problem down to facts that can't be split further, then build back up. Musk: "boil things down to the most fundamental truths … and then reason up from there." Battery case: the $600/kWh conventional wisdom → the commodity price of the materials (cobalt, nickel, aluminum, carbon, polymers, steel) added up to $80 — the expensive part was assembly convention, not physics.
- **Misuse boundary**: redesigning already-proven solutions down to the atom (reinventing the wheel) — use first principles only where you're stuck or where it's expensive.
- **Procedure**: ① list every assumption in the current plan ② for each, ask "is this a physical fact or a convention?" ③ drop the conventions and reassemble from facts alone.
- **Nudge trigger**: when the reasoning starts with "usually / normally / everyone". When only improvements to the existing approach are discussed and nobody asks "why this approach at all?"
- **Example**: "That's reasoning by analogy — at the root, the only physical constraint here is X; Y is convention. Drop Y and a different design opens up."

## 2. Working backwards (PR-FAQ — Amazon)

- **Principle**: before building, **write the finished press release and FAQ first**. If you can't write what you'd announce to customers, you don't yet know what you're building.
- **Procedure**: one-page press release (customer problem → solution → customer quote) + two FAQs (external: customers and press / internal: leadership's skeptical questions) → if that doesn't persuade, don't start.
- **Misuse boundary**: writing it after the fact to justify what's already built, or a glossy PR with a thin FAQ — the point is that it's a gate *before* starting.
- **Nudge trigger**: implementation starts without a definition of the final result. "Let's just build it and see" comes up a second time.
- **Example**: "Can you write, in one line, what you'd post in Slack when this ships? If not, it isn't defined yet."

## 3. Kinds of doors (one-way vs two-way — Bezos)

- **Principle**: decisions come in two kinds. **One-way doors (Type 1)** can't be undone — go slowly and carefully. **Two-way doors (Type 2)** can — go fast and bold (Bezos, 2015 shareholder letter — the 1997 attribution is a common error). Most decisions are Type 2, yet organizations treat them all as Type 1 and slow down. Individuals make the opposite mistake — deciding Type 1 on a whim.
- **Nudge trigger**: an irreversible decision (deletion, going public, structural change, final naming) made lightly / a reversible decision overthought.
- **Example**: "This is a two-way door — not worth 30 minutes. Try it and roll back if needed." / "This is a one-way door — sleep on it."

## 4. Inversion + pre-mortem (Munger / Klein)

- **Principle**: instead of "how do we succeed", first list **"how would we surely fail"** and avoid that (Munger, 2007 USC Law commencement: "Invert, always invert" — quoting Jacobi). Pre-mortem (Klein, HBR 2007): ① declare the project has already failed ② everyone silently writes why ③ share one by one — prospective hindsight improves identification of failure causes by about 30%.
- **Nudge trigger**: the plan has only a success path, with no failure scenario or rollback.
- **Example**: "If nobody is using this a month from now, why? My guess: X. We can prevent that today."

## 5. Second-level thinking (Howard Marks; "second-order" is a later label)

- **Principle**: don't stop at first-level thinking ("good company, buy"). Ask "does everyone think so? and then what?" Good first-order effects often produce bad second-order ones (add notifications → convenient → notification fatigue → all ignored).
- **Misuse boundary**: contrarianism for its own sake isn't second-level thinking — understand the consensus and its reasoning, then find where it breaks.
- **Nudge trigger**: only the direct effect of a change is discussed. Especially "add" decisions (the second-order effect of adding is usually complexity).
- **Example**: "First-order it's more convenient, but second-order X grows and Y breaks — same family as the badge we removed."

## 6. Three kinds of work (LNO — Shreyas Doshi)

- **Principle**: not every task deserves the same quality (Doshi, 2020). **L (leverage)**: 10x value — do it at your best. **N (neutral)**: fair value — do it well enough. **O (overhead)**: necessary but low value — minimum quality, fast. Spending perfectionism on O is the worst waste.
- **Misuse boundary**: labeling every unpleasant but necessary task O to avoid it — L/N/O shifts with context.
- **Nudge trigger**: craftsmanship poured into overhead (cleanup, chores) / leverage work (direction, design) rushed through.
- **Example**: "This is O-level work getting L-level effort — that time would unblock pending item #1 (L-level)."

## 7. Jobs to be done (JTBD — Christensen)

- **Principle**: people don't buy products; they **hire them to get a job done** ("people don't want a quarter-inch drill, they want a quarter-inch hole"). Milkshake case: the morning commuter hired it to "make a boring drive bearable, one-handed" — the competition was bananas and bagels, not other shakes.
- **Misuse boundary**: confusing a job with a feature request or a demographic persona; job statements too vague to act on ("I want to do my work better").
- **Nudge trigger**: there's a feature spec but no "who picks this up, at what moment, and why".
- **Example**: "When does this feature get hired? What do they use in that moment today? That's the real competitor."

## 8. Double diamond (UK Design Council)

- **Principle**: diverge → converge **twice** (UK Design Council, 2005): once in the problem space (Discover → Define), once in the solution space (Develop → Deliver). The common failure is skipping the first diamond — diverging on solutions with no problem definition.
- **Misuse boundary**: running it one-way left to right (waterfall) — the authors formally added iteration in 2019. Moving back and forth between diamonds is normal.
- **Nudge trigger**: converging straight onto the first idea (zero alternatives). Solution talk starting without a problem definition.
- **Example**: "You're in the second diamond but skipped the first — what's the problem statement this solves?"

## 9. Five whys (Toyota / Ohno)

- **Principle**: from a symptom, repeat "why" down the chain of causes (5 is a direction, not a fixed number). Ohno's original: machine stopped → fuse (overload) → poor bearing lubrication → pump not delivering → worn shaft → **no strainer** — the answer was installing a strainer, not replacing the fuse. Stop when you reach a process or structure, not a person to blame.
- **Misuse boundary**: following one chain when causes branch; steering toward an answer you already suspect (confirmation bias).
- **Nudge trigger**: symptom-only patches keep repeating (two incidents of the same family = a structural signal).
- **Example**: "That's the second incident of this family today — three whys down, the cause is structure X, not a patch."

## 10. Must-be / performance / delight (Kano)

- **Principle**: quality comes in three kinds (Kano et al., 1984). **Must-be** (anger if missing, indifference if present — saving, stability), **performance** (more is better — speed), **delight** (indifference if missing, delight if present — the pet's heart). Seal the holes in must-be before stacking delight.
- **Misuse boundary**: classifications aren't permanent — delight **decays** into must-be over time (as touchscreens did). Don't trust last year's delight classification this year.
- **Nudge trigger**: delight (decoration, fun) is being discussed while a must-be hole (reliability, data safety) is open.
- **Example**: "That's delight quality, but there's an open must-be hole (X) — let's swap the order."

## 11. Outcomes over output (Cagan) + opportunity cost

- **Principle**: judge by whether user behavior changed (outcome), not how many features were built (output). And every "let's do it" carries an invisible "then what won't we do?" (opportunity cost).
- **Nudge trigger**: "done" is defined as "built". A plan with only additions and nothing given up.
- **Example**: "What won't you be able to do if you take this on? That slot held pending item #2 — is this impactful enough to swap?"

## Discipline (the quality bar for nudges)

- **Only 1–3 lenses** — the one that hurts most right now. Listing everything = lecture = noise.
- Nudges are **specific**: which lens, what's missing, what to do — grounded in {{USER}}'s actual cards (records) where possible.
- If {{USER}}'s decision conflicts with a lens, **point it out once; if they reconfirm, follow** — Gari meddles, it doesn't stonewall.

## Sources (web-verified 2026-07-06 — includes two attribution corrections)

- First principles: Musk, Kevin Rose interview 2012 (via republished copy) · Working Backwards: workingbackwards.com, theprfaq.com
- Kinds of doors: **confirmed against Bezos's 2015 shareholder letter** (the 1997 attribution is wrong — no source PDF found)
- Inversion: **confirmed as Munger's 2007 USC Law commencement** (the 1994 attribution is wrong) · Pre-mortem: Klein, HBR 2007-09
- Second-level thinking: Marks's original term is second-level (Oaktree memos, via secondary sources)
- LNO: Doshi's original tweet, 2020 · JTBD: HBS milkshake marketing · Double diamond: Design Council official (2005 / revised 2019)
- 5 Whys: Ohno's original example (cross-checked with the lean community, original not compared) · Kano: 1984 paper bibliography confirmed (Japanese original not compared)
