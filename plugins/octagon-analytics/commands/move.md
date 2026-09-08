---
description: Move a candidate to a new hiring stage on a job. Preview first, applies only on your confirmation.
---

Usage: `/move Jamie Adams to 1st Interview on Contract Electro-Mechanical Assembler`

**Step 1 — resolve.** Call `find_candidate` with the name to get their `candidate_slug` and the
jobs they are on. If the job was named, confirm it with `job_pipeline`. If either the candidate or
the job is ambiguous, STOP and list the matches — never guess which person is meant.

**Step 2 — preview.** Call `update_hiring_stage` with `candidate_slug`, `job_slug` and the target
`status_id`, WITHOUT `confirm`. Valid stages:

| Stage | status_id |
|---|---|
| CV Sent | 390955 |
| Interview Request | 381800 |
| 1st Interview | 381799 |
| 2nd Interview | 381801 |
| Offered | 381805 |
| Placed | 8 |

If the recruiter asks for a stage not in that table (3rd Interview, Shortlist, a rejection), say you
do not have a verified status_id for it and stop. Do not guess an id — a wrong one moves the
candidate to the wrong stage in live RecruitCRM.

**Step 3 — show and ask.** Show the preview verbatim: candidate, job, current stage, proposed
stage. Ask for explicit confirmation.

**Step 4 — apply.** Only after a clear yes, call again with `confirm: true` AND
`expected_status_id` set to the current status_id from the preview. If the write is refused because
the stage changed, someone else moved them meanwhile — re-run the preview, do not retry blindly.

Moving to **Placed** also needs `create_placement: true`. Say plainly that Placed carries no fee:
billing is recorded by moving the DEAL to Won and entering the value, which is `/won`, a separate
step people forget.

One move per confirmation. If several are asked for, preview and confirm them one at a time.
