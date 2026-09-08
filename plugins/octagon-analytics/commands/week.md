---
description: Current week stats — actuals against weekly targets for every KPI, with the gap named.
---

Call `weekly_kpis` from the **octagon-analytics** connector. It returns this week's actuals
(from Monday) against each consultant's weekly targets and renders as an inline scorecard.

If the widget renders, do not restate the whole table in prose — give the headline and the
exceptions only. If you cannot confirm it rendered, present the figures as a compact markdown
table instead. Never claim it "rendered above" unless you can see that it did.

State the week start as DD/MM/YYYY.

Targets are 10 CV sends, 5 interview requests, 4 interviews, 5 BD calls and 5 client calls per
recruiter per week. Placements have no weekly target — billing is quarterly.

Call out, in this order:
1. Anyone **behind** on a target, with the gap as a number and one specific next action.
2. Anyone **ahead** worth noting, briefly.

Mandatory caveat on the two call metrics: they count only calls categorised in Devyce, and
firm-wide only about **10%** of calls are categorised. Treat them as a floor. A consultant showing
zero BD calls has very likely made them without tagging — check before treating it as a miss.
