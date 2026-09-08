---
description: Reference data from RecruitCRM — the valid IDs behind stages, types and statuses.
---

Usage: `/ref pitch_stages` — `/ref off_limit_status` — `/ref` to see what kinds exist

Call `reference_list` with the `kind` asked for.

This exists so nobody guesses an ID. Several write tools take numeric ids — pitch stages, off-limit
statuses, meeting and task types — and a wrong id silently writes the wrong thing to live
RecruitCRM without erroring. Look it up here first, every time.

Present as a compact table: id and label.

If a `kind` is not recognised, say which kinds are available rather than guessing at a close match.

Hiring stage ids are the exception — those are fixed and verified in `stage_lookup`, and `/move`
carries the full table.
