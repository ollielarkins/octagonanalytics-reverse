---
description: Evening calls — who was on the phone after 17:00, by hour, independent of call tagging.
---

Call `call_hours_report` from the **octagon-analytics** connector.

Default to the last 7 days. If the user named a window or a consultant, pass `from`, `to` and
`consultant`. `evening_from` defaults to 17 (5pm) — pass a different hour only if asked.
State the window as DD/MM/YYYY.

Present:
- **Headline**: total calls, evening calls, evening share to 1 dp.
- **By consultant**: evening calls and how many connected, highest first. Omit anyone with none.
- **By hour**: a compact table, but only the hours with activity — do not pad out empty hours.

This report counts **all** calls, tagged or not, so unlike the BD and client-call KPIs it does not
depend on anyone remembering to categorise. Say so once: it is the reason this number can be
trusted where those cannot.

Read it as information, not virtue. Evening calling suits some desks and some candidate markets
and means nothing on its own — do not congratulate or criticise anyone on this number. If asked
who is "best", say the metric does not support that.
