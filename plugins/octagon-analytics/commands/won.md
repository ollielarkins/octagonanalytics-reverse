---
description: Mark a deal as Won and enter the value — this is how billing is recorded.
---

Usage: `/won the Rheinmetall Systems Engineer deal at 8500`

**This is the billing action.** At Octagon, revenue is recorded by moving the Deal to Won and
entering the value. A candidate sitting at the Placed stage carries no fee — the deal is what bills.
That gap is the single most common reason billing looks lower than the desk feels.

**Step 1 — resolve the deal.** `update_deal` accepts a deal ID, slug, or part of the name. If the
name is partial and could match more than one deal, ask which rather than guessing — putting the
wrong deal to Won misstates revenue.

**Step 2 — get the value right.** Do not infer, estimate or calculate a fee the recruiter has not
given you. If they have not said the value, ask. If they give a percentage and a salary, you may
show the arithmetic, but they confirm the final number, not you.

**Step 3 — the close date matters more than people think.** `close_date` is what several reports
key off. Deals here are routinely marked Won with a **forward** close date, which is why
`placements_report` shows far less revenue than `/placements` for the same placements. Ask for the
close date explicitly rather than letting it default, and say why it matters.

**Step 4 — preview, then confirm.** Call `update_deal` without `confirm`, show the before/after
verbatim — name, current stage, new stage, value, close date — get an explicit yes, then confirm.

State money as £ with thousands separators.

Do not present this as "billing confirmed". It records the deal as Won; whether it is invoiced or
paid is not visible in this platform at all.
