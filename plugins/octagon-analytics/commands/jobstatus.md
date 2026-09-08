---
description: Open roles by status — what is actually live, on hold, closed or cancelled.
---

Usage: `/jobstatus` — `/jobstatus Keelan Riley`

There is no dedicated tool for this, so build it from what is available:
1. `cold_jobs` with a large `days` value lists open roles and their last activity.
2. `job_pipeline` gives detail on any single role.
3. `new_jobs_report` covers roles created recently.

Present open roles with: title, client, owner, days since last activity, and how many candidates
are in play. Sort by days since activity, coldest first.

Useful context on the shape of the book: job statuses run roughly Closed ~5,800, Open ~135,
Canceled ~19, On Hold ~12. The overwhelming majority of jobs are closed history, so any "total
jobs" figure is meaningless as a measure of current workload — always report open roles, not total.

If someone asks how many jobs they have, they almost always mean live roles. Answer that, and give
the total only if they want it.

To change a job's status, use `/editjob`.
