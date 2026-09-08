---
description: Edit a job — close it, put it on hold, change the salary range or title.
---

Usage: `/editjob close 6011` — `/editjob put the Bosch role on hold` — `/editjob 6011 salary 55000-65000`

Identify the job by numeric ID, slug, or part of the title. If a partial title matches more than one
job, list them and ask — closing the wrong role is disruptive and not obvious to anyone until a
candidate asks.

Status values: `open`, `closed`, `on hold`, `cancelled`.

**Closed vs cancelled vs on hold matters** and people use the words loosely:
- `closed` — the role is done, usually filled
- `cancelled` — the client pulled it
- `on hold` — paused, expected back

If the recruiter says "close it" and the role was pulled by the client, check which they mean. It
changes what the reporting says about why roles end.

**Preview, then confirm.** Call `update_job` without `confirm`, show before/after, get an explicit
yes, then `confirm: true`. Only the fields you pass change.

If they are closing a role because it was filled, remind them the placement and the deal are
separate: the candidate goes to Placed via `/move`, and the fee is recorded by moving the deal to
Won via `/won`. Closing the job alone records no revenue.
