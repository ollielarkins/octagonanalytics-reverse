---
description: Assign a candidate to a job. Preview first, applies only on your confirmation.
---

Usage: `/assign Priya Shah to the Senior Systems Engineer role`

**Step 1 — resolve.** `find_candidate` for the candidate slug, `job_pipeline` for the job. If either
is ambiguous, list the matches and stop rather than picking one.

**Step 2 — check they are not already on it.** `find_candidate` returns the jobs they are on. If
they are already assigned, say so and stop — do not create a duplicate assignment.

**Step 3 — check off limit.** Call `off_limit` with `action: check`. Around 88 candidates are off
limit, usually because they were recently placed. If this candidate is off limit, STOP and say so.
Do not assign them, and do not offer a workaround.

**Step 4 — preview, then confirm.** Call `assign_candidate` without `confirm`, show the preview
verbatim, get an explicit yes, then call again with `confirm: true`.

Assigning puts them in the pipeline at the starting stage. To move them onward afterwards, use
`/move`. Candidate names are PII — internal only.
