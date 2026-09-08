---
description: Interview requests that were never booked in — candidates waiting on a date.
---

Call `interview_requests_unbooked` from the **octagon-analytics** connector. Default
`within_days: 30`; pass `consultant` if the user narrows it. State the window.

Present:
- **Headline**: how many requests are outstanding.
- **By consultant**, highest first.
- **The list**: candidate, job, consultant, date requested (DD/MM/YYYY), days waiting — longest
  waiting first.

Candidate names are internal PII. Do not put them in anything client-facing, and do not export
them in bulk.

Two things to be straight about:
- The window matters. There are several hundred of these going back years; they are abandoned
  history, not a backlog. Only the recent window is a real to-do list, which is why the default
  is 30 days. If the user asks for everything, give it but say plainly that most of it is dead.
- "Not booked" means nothing has been recorded since the request — no interview, no rejection,
  no placement. The interview may well have happened and not been logged.

Lead with the longest-waiting few as the ones to chase. Nudge, don't nag.
