---
description: New jobs added, and which are missing a completed job order form.
---

Call `new_jobs_report` from the **octagon-analytics** connector. Default to the last 7 days; pass
`from`, `to` or `consultant` if the user narrows it. State the window as DD/MM/YYYY.

Present:
- **Headline**: new jobs, how many have a job order form, completion rate to 1 dp.
- **By consultant**: new jobs, with form, missing form — most new jobs first.
- **Missing the form**: job title, owner, date created (DD/MM/YYYY). This is the actionable list.

State plainly, every time: a missing form means **the note was never logged**. It does not prove
the qualifying call did not happen. Report it as a chase, not a failure — the fix is usually two
minutes of admin, not a performance conversation.

Firm-wide completion has been running around 25%, so expect most new roles to show as missing. If
the rate is that low, the useful observation is that the process is not being followed at all
rather than that any individual is behind.

At most three next actions — usually the oldest roles still without a form.
