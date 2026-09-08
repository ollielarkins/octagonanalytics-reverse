---
description: Log a client visit or meeting in RecruitCRM. Client visits are a reported KPI.
---

Usage: `/meeting Rheinmetall site visit yesterday 14:00-15:30`

Calls `log_activity` with `kind: meeting`. Meetings need a `start` AND an `end`, both as
`YYYY-MM-DD HH:MM`. Link it to a client, job or candidate so it shows against that record.

**Client visits are reported as meetings** — this is the only place they live, and they only count
if they are logged. If a recruiter mentions a visit in passing, offer to log it.

Resolve relative dates against today's date, which is in your context. If the recruiter says
"yesterday" on a Monday, check whether they mean Sunday or Friday rather than assuming.

If they give a start but no end, ask for a duration rather than defaulting to an hour — a logged
meeting with an invented length is a fabricated record.

**Preview, then confirm.** Call `log_activity` without `confirm`, show it verbatim, get an explicit
yes, then `confirm: true`.

`type_id` comes from `reference_list` if they want a specific meeting type — do not guess an id.
