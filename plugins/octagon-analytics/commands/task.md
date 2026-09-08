---
description: Set a task or reminder in RecruitCRM against a client, job or candidate.
---

Usage: `/task chase Sarah at Rheinmetall for feedback Friday 09:00`

Calls `log_activity` with `kind: task`. Tasks need only a `start`, as `YYYY-MM-DD HH:MM`. Link it to
a client, job or candidate so it appears against that record rather than floating loose.

Resolve relative dates ("Friday", "next week") against today's date, which is in your context, and
state the resolved date back as DD/MM/YYYY so a misread is caught before it is written.

If no time was given, ask rather than defaulting — a task at 00:00 is a task nobody sees.

**Preview, then confirm.** Call `log_activity` without `confirm`, show it verbatim, get an explicit
yes, then `confirm: true`.

Created by and owned by the acting consultant.
