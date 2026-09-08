---
description: Add a note to a candidate or a job. Preview first, applies only on your confirmation.
---

Usage: `/note on Jamie Adams: spoke re salary, wants 55k, available from October`

**Step 1 — resolve.** `find_candidate` for a candidate, `job_pipeline` for a job. Get the slug. If
ambiguous, list matches and stop.

**Step 2 — draft.** Write the note in the recruiter's own words. Tidy grammar and spelling, but do
NOT add facts, inferences or salary figures they did not give you. If something is unclear, leave
it as they said it rather than smoothing it into something more definite than the truth.

**Step 3 — preview, then confirm.** Call `add_note` without `confirm`, show the exact text that
will be written, get an explicit yes, then confirm.

The note is attributed to the acting consultant from their token, so it appears under their name.

Worth knowing: notes carry the KPI types (Lead, Candidate - Internal Interview, Job Order Form
Complete), but `add_note` writes an untyped note — it cannot set the type. Around 88% of recent
notes are untyped, which is why those KPIs under-report. If the recruiter is logging something that
should count as a lead or a job order form, tell them to set the type in RecruitCRM itself,
otherwise it will not appear in `/newjobs` or the notes KPIs.
