---
description: Client visits and meetings logged in RecruitCRM — the only place visits are recorded.
---

Usage: `/visits` — `/visits Keelan Riley last month` — `/visits tasks`

Call `activity_report` with `kind: meetings` (default) or `kind: tasks`. Defaults to the last 30
days and to whoever is asking; pass `consultant` for someone else, or `all: true` for the firm.
State the window as DD/MM/YYYY.

**Client visits live here and nowhere else.** No other report covers them, and they only exist if
someone logged them. So a low count means little on its own — it may mean no visits, or it may mean
visits that nobody recorded. Say which you can and cannot tell.

Present: date (DD/MM/YYYY), title, linked client or job, consultant. Newest first, plus a per-
consultant count if reporting for the firm.

For `tasks`, present outstanding ones first with their due date, and flag anything overdue.

If someone mentions a visit in conversation that is not on this list, offer to log it with
`/meeting`. The gap between visits made and visits recorded is the whole problem with this metric.
