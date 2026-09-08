---
description: Take a candidate off a job, or hide/show them on the client shortlist.
---

Usage: `/unassign Priya Shah from the Bosch role` — or `/unassign hide Priya Shah on the Bosch role`

Actions available through `manage_assignment`:
- `unassign` — removes them from the job's pipeline entirely
- `hide` / `show` — controls whether the client sees them in the shortlist
- `apply` — records them as having applied

**Default to nothing.** If the recruiter just says "take X off Y", confirm they mean `unassign`
(removes from pipeline) rather than `hide` (client no longer sees them) — these are very different
and the words get used interchangeably. Ask before acting.

**Resolve first**, then call `manage_assignment` without `confirm`, show the preview verbatim, get
an explicit yes, then confirm.

Two things to say when unassigning:
- It removes them from the pipeline. If the intent was only to change their stage — including
  rejecting them — `/move` is the right tool and keeps the history intact.
- Their stage history stays in the reporting, so unassigning does not erase past activity.

One assignment per confirmation.
