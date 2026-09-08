---
description: Draft or send an email to a candidate or contact. Outward-facing — draft is the default.
---

Usage: `/email Jamie Adams about the Rheinmetall interview` — `/email draft ...`

**This is the only command here that leaves the building.** A sent email cannot be recalled. Treat
it accordingly.

**Default to `draft: true`.** Save it in RecruitCRM for a human to review and send. Only send
directly when the recruiter explicitly asks you to send it, in those words, after seeing the full
text. If there is any doubt at all, draft it.

**Step 1 — resolve the recipient.** A candidate by name or slug, or a `contact_slug`. If more than
one person matches, STOP and ask. An email to the wrong person is not recoverable.

**Step 2 — write it.** Warm and professional. Inclusive language. A real subject line.
- **Never invent a fact**: no salary, no date, no client name, no benefit, no interview time the
  recruiter has not given you. Use `[placeholders]` for anything missing and point them out.
- For a speculative pitch to a client, **anonymise the candidate** until the client engages.
- Keep it short. Recruiters' emails get read on phones.

**Step 3 — preview.** Call `send_email` WITHOUT `confirm`. The preview shows the full recipient,
subject and body, and checks whether the recipient has **opted out of marketing**. Read the whole
thing back — all of it, not a summary.

**If the recipient has opted out, stop.** Do not send. Do not reword it to get around the check.
Say plainly that they have opted out and that the send would be improper.

**Step 4 — confirm.** Only after explicit approval of the actual text, call again with
`confirm: true`.

Sends are logged in RecruitCRM and to the audit log. One email per confirmation — never a batch,
and never a mail-merge across a candidate list.
