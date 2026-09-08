---
description: Match candidates to a job description by skills. Off-limit candidates excluded automatically.
---

Usage: `/match` then paste the JD — or `/match C++, embedded, RTOS, Bristol`

**If given a job description**, extract the key skills yourself first — the real technical
requirements, not the boilerplate. Then call `match_candidates` with them as `skills`, plus
`location` if the role is geographically constrained.

Present, ranked by match count:
- Candidate, matched skills, recent roles — the recent roles are what let the recruiter judge fit.
- Say how many matched in total and how many you are showing.

**State the coverage limit every time:** only candidates with skill text populated are considered,
which is about **73%** of the database. A candidate missing from these results may simply have no
skills recorded — this is a starting point for a search, not a complete answer, and it should never
be presented as "there is nobody".

Off-limit candidates are excluded automatically and the count appears as `off_limit_excluded` —
report that number. Do not pass `include_off_limit` unless the recruiter explicitly asks and has a
reason, and even then say clearly that those people must not be approached.

Skill-substring matching is crude: it finds the word, not the depth. Rank is a prompt to look, not
a judgement of quality. Say so rather than presenting the order as a ranking of who is best.

Candidate names are PII: internal only.
