---
description: Yesterday's activity — CV sends, interview requests, interviews booked, call stats and placements, per consultant.
---

Report the previous **working** day. Today's date is in your context: use yesterday, except on a
Monday where "yesterday" means the previous Friday. State the date you used as DD/MM/YYYY.

Call these tools from the **octagon-analytics** connector, with `from` = that date and
`to` = the following day (the window is end-exclusive, so a single day is from=D, to=D+1):

1. `funnel_report` — CV sends, interview requests and interviews booked
2. `call_activity` — call volume, connect rate and category breakdown
3. `placements_report` — anything placed

Present as compact tables, highest first:

- **Headline line**: CV sends, interview requests, 1st interviews, placements — firm totals.
- **Per consultant**: CV Sent, Interview Request, 1st Interview. Stage order is always
  CV Sent → Interview Request → 1st → 2nd → 3rd → Offered → Placed. Omit stages with no activity.
- **Calls**: total, connected, connect rate to 1 dp, then BD and client calls per consultant.
- **Placements**: consultant, client, and Won deal value in £ with thousands separators.

Two caveats you MUST include when you report call numbers:
- BD and client calls count only calls a recruiter has categorised in Devyce. Firm-wide only
  about **10%** of calls carry a category, so these are a floor, not an actual. Never present them
  as a performance judgement on their own.
- If any consultant shows 0 BD and 0 client calls but a non-zero total call count, say explicitly
  that this is untagged calls rather than no activity.

A quiet day is a quiet day — do not editorialise or pad. Finish with at most three next actions,
and only if something genuinely needs chasing.
