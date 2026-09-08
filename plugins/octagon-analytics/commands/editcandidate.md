---
description: Edit an existing candidate record. Before/after preview, applies only on your confirmation.
---

Usage: `/editcandidate Jamie Adams — salary expectation 60000, notice 1 month`

**Step 1 — resolve.** Identify them by name or slug. If more than one matches, list and ask. Never
edit the wrong person's record on a guess.

**Step 2 — change only what was asked.** Only the fields you pass are altered. Do not tidy up other
fields you happen to notice, do not reformat a phone number, do not correct a name's capitalisation
unless asked. Unrequested edits are how a record quietly drifts from what the candidate actually
told someone.

**Step 3 — preview, then confirm.** Call `update_candidate` without `confirm`, show the before/after
verbatim so they can see exactly what changes, get an explicit yes, then `confirm: true`.

Note `notice_period` is in **days** — if the recruiter says "one month", ask whether they mean 28 or
30 rather than picking one.

RecruitCRM demands `first_name` on every edit, so the tool reads the record first and carries it
forward. That is handled; you do not need to pass it.

Candidate details are PII: internal only.
