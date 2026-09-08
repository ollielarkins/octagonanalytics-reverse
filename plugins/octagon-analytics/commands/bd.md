---
description: BD progress — yesterday's prospect activity plus the current account-status pipeline.
---

Two parts. State the window as DD/MM/YYYY.

**1. Yesterday's BD activity.** Call `call_activity` from the **octagon-analytics** connector with
`from` = the previous working day and `to` = the day after it. Report calls categorised
`Contact - Prospect (BD)`: count per consultant, connected vs attempted, and connect rate to 1 dp.

**2. Account pipeline.** Call `bd_report` for the standing company-status breakdown (Prospect,
Engaged, Client, Passive, Blocklisted, Do-not-contact).

Present both as compact tables, highest first.

Caveats you MUST state:
- BD calls count only calls categorised in Devyce. Firm-wide about **10%** of calls carry a
  category, so this is a floor. A recruiter showing zero BD calls may simply not be tagging.
- BD calls counted here are **attempts**, not conversations — the firm-wide connect rate on BD
  calls is around 20%. If the business means conversations by its target of 5 a week, this number
  answers a different question; say so rather than implying the target was met.
- `bd_report`'s own description claims job order forms are not tracked. That is out of date —
  they are logged as a note type. Do not repeat that claim.

Close with the prospects worth chasing today, at most three.
