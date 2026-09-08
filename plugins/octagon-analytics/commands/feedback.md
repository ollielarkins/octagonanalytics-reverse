---
description: Candidates interviewed with no feedback logged since — silence in the system.
---

Call `awaiting_feedback_report` from the **octagon-analytics** connector. Defaults are
`min_days: 2` and `within_days: 30`; pass `consultant` if the user narrows it. State the window.

Present:
- **Headline**: how many candidates are sitting with nothing logged.
- **By consultant**, highest first.
- **The list**: candidate, job, consultant, interview date (DD/MM/YYYY), days since — longest
  silence first.

Candidate names are internal PII — internal use only, no bulk export, never client-facing.

The caveat is not optional and must appear every time: this measures **silence in the system**,
not absence of feedback. It counts candidate-job pairs with no Interview Feedback call, no
candidate note and no move to offered, placed or rejected since the interview. Feedback may have
been given verbally and never written down. Present it as "nothing recorded", never as "no
feedback given" or "candidate ignored".

That distinction matters because a candidate genuinely left hanging after an interview is a real
duty-of-care problem, and a logging gap is not — and this report cannot tell you which it is.
Say which candidates need checking, not which recruiters are at fault.
