---
description: Notes KPIs — leads, internal interviews and job order forms logged, by consultant.
---

Usage: `/noteskpi` — `/noteskpi this month`

Call `notes_kpi`. Defaults to this month; pass `from`, `to` or `consultant`. State the window as
DD/MM/YYYY.

Present:
- **Headline**: leads, internal interviews, job order forms, all notes.
- **By consultant**, most leads first.
- The by-type breakdown if useful.

**The coverage caveat is mandatory.** These three KPIs are note *types*, and around **88%** of
recent notes are untyped. A consultant showing zero leads has very probably logged leads as untyped
notes. This measures typing discipline at least as much as activity — never present a zero as
inactivity, and never use these numbers in a performance conversation without saying so.

Also worth knowing: `/note` and the connector's `add_note` cannot set a note type at all, so
anything logged through this platform lands untyped and will not count here. If someone wants their
leads to register, they have to set the type in RecruitCRM itself. That is a real product gap, not
a user error.

Around 84,000 notes are `Migrated` legacy records from 2018-2024 — excluded from any recent window,
but they dominate all-time totals, so never quote a lifetime note count as activity.
