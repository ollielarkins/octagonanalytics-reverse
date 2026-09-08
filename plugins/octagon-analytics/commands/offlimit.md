---
description: Check, list, mark or release off-limit candidates — who must not be approached.
---

Usage: `/offlimit check Jamie Adams` — `/offlimit list` — `/offlimit mark Jamie Adams until 2027-03-01`

Calls `off_limit`. Actions:
- `list` — everyone currently off limit (read-only)
- `check` — one candidate, with history (read-only)
- `mark` — set off limit until a date (WRITE)
- `release` — make available again (WRITE)

`list` and `check` are read-only: just run them and report.

`mark` and `release` are writes — preview first, show it verbatim, get an explicit yes, then
`confirm: true`.

Be careful with **release**. Off limit usually means recently placed, and releasing someone early so
they can be approached again is exactly the situation the list exists to prevent. Ask why before
previewing, and if the reason is "we need candidates for this role", say plainly that this is not a
good enough reason and leave it. That is not obstruction — it is the client relationship the list
protects.

For `mark`, `until` is YYYY-MM-DD and `status_id` comes from `reference_list` with
`kind: off_limit_status`. Ask for a reason and record it.

Note the sync currently matches 87 off-limit candidates against a standing figure of 88 — if the
count matters to the decision, say the two do not quite agree rather than quoting either as exact.
