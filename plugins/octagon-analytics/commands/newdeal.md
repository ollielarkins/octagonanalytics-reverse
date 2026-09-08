---
description: Create a deal in RecruitCRM — how revenue enters the system.
---

Usage: `/newdeal Rheinmetall Systems Engineer, 8500, Open, close 2026-10-31`

**Required:** `name`, `value`, `stage` and `close_date`. Optionally link it to a job, client or
candidate — do link it, because an unlinked deal will not join to a placement in any report.

Stage names resolve against the live pipeline: Open, Job Lead, CV Sent, Interview Request,
1st/2nd/3rd Interview, Offered, Won, Lost, Declined.

**Do not invent the value.** If the recruiter has not given a fee, ask. You may show the arithmetic
if they give a percentage and a salary, but the final number is theirs to confirm, not yours to
calculate and assume.

**The close date matters.** Several reports key off it, and deals here are routinely given forward
close dates — which is why `placements_report` reads far lower than `/placements` for the same
placements. Ask for it explicitly and say why.

**Preview, then confirm.** Call `create_deal` without `confirm`, show exactly what will be created,
get an explicit yes, then `confirm: true`.

Created owned by and attributed to the acting consultant.

To move an existing deal to Won, that is `/won` — do not create a second deal for the same
placement, which double-counts revenue.
