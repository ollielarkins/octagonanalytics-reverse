---
description: Look up a job and see who is in play, with each candidate's current stage.
---

Usage: `/pipeline 6011` — `/pipeline Senior Systems Engineer`

Call `job_pipeline`. It accepts a numeric job ID as shown in RecruitCRM, an exact slug, or part of
the title.

Present the candidates in play grouped by stage, in funnel order: CV Sent → Interview Request → 1st
→ 2nd → 3rd → Offered → Placed. Show the job title and client above it.

`matched: 0` means the job genuinely is not there — say that, rather than searching around for
something similar and presenting it as the answer.

If several jobs match a partial title, list them with their IDs and ask which.

Useful before `/move` or `/assign`, since it gives you the job slug and shows who is already on the
role.

Candidate names are PII: internal only.
