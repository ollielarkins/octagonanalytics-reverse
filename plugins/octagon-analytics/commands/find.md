---
description: Find a candidate — their slug, and every job they are on with the current stage.
---

Usage: `/find Jamie Adams`

Call `find_candidate` with the name. Partial matches work.

Present:
- Each match: name, and the jobs they are on with their current stage.
- Their `candidate_slug`, because that is what every write command needs.

If several people match, show them all — do not pick one. This command exists precisely so the
recruiter chooses before anything acts on a record.

If nothing matches, say so plainly. It means the candidate genuinely is not in RecruitCRM, or is
retired — do not speculate further or offer near-miss names as if they were the person.

For the fuller picture — work history, education, every job — use `candidate_profile` instead.

Candidate names and details are PII: internal only, never client-facing, no bulk export.
