---
description: Open roles with no candidate activity in the last 7 days, oldest first.
---

Call `cold_jobs` from the **octagon-analytics** connector with `days: 7`.

If the user named a consultant, pass `consultant`. Otherwise report the whole firm.

Present oldest-cold first as a compact table: job title, client, owning consultant, days since
last activity. Job titles and clients only — no candidate names.

Then, briefly:
- Which consultant carries the most cold roles.
- The single oldest role, named, as the one to unblock first.

A role going cold for 7 days is a nudge, not a failure — some roles are legitimately on hold.
Say what needs a decision rather than implying neglect. At most three next actions.
