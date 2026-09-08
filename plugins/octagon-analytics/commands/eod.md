---
description: End-of-day stats — today's activity so far against where the week needs to be.
---

Report **today** (the date is in your context; state it as DD/MM/YYYY) and how it leaves the week.

Call from the **octagon-analytics** connector:

1. `funnel_report` with `from` = today and `to` = tomorrow — today's stage activity
2. `call_activity` for the same single-day window
3. `weekly_kpis` — week-to-date actuals against targets

Present in this order:

- **Today**: CV sends, interview requests, 1st interviews, placements. Firm total, then per
  consultant, highest first. Stage order CV Sent → Interview Request → 1st → 2nd → 3rd → Offered
  → Placed.
- **Calls today**: total, connected, connect rate to 1 dp.
- **Week to date vs target**: for each consultant show actual/target and the gap. Weekly targets
  are 10 CV sends, 5 interview requests, 4 interviews, 5 BD calls, 5 client calls.

For anyone behind, say **by how much** and name the single next action — not a list. Nudge, don't
nag: one line each, no lecture. If someone is on track, say so in three words and move on.

Include the call-tagging caveat: BD and client call figures count only categorised Devyce calls
(~10% firm-wide coverage), so they under-report. Do not tell someone they missed a call target
without that qualifier.
