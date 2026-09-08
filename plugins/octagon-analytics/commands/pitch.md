---
description: Record a speculative pitch — candidate pitched to a client contact. Off-limit checked first.
---

Usage: `/pitch Jamie Adams to Rheinmetall` — or `/pitch Jamie Adams to Sarah Kelly at Rheinmetall`

**Step 1 — off-limit check, always, before anything else.** Call `off_limit` with `action: check`
for the candidate. Around 88 candidates are off limit, usually because they were recently placed.
If this candidate is off limit, STOP. Say so plainly, do not record the pitch, and do not suggest a
way around it. Pitching a placed candidate back to the market is a serious client problem.

**Step 2 — resolve both sides.** The candidate by name or slug; the contact by `contact_slug`, or by
`client` (company name) plus `contact_name`. If the company has several contacts and none was named,
list them and ask which — a pitch recorded against the wrong person is worse than none.

**Step 3 — preview, then confirm.** Call `pitch_candidate` without `confirm`, show the preview
naming both people verbatim, get an explicit yes, then confirm.

If the recruiter wants to move an EXISTING pitch to a different stage instead of creating one, pass
`stage_id` — get the valid ids from `reference_list` with `kind: pitch_stages` rather than guessing.

This records the pitch in RecruitCRM. It does not send anything to the client. If they want the
actual outreach written, that is a separate request — and any spec pitch to a client should be
anonymised until the client engages.
