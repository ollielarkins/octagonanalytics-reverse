---
description: Add a new candidate to RecruitCRM. Duplicate-checked, preview first.
---

Usage: `/newcandidate Priya Shah, priya@example.com, 07700 900123, Senior RF Engineer at Filtronic`

Only a first name is strictly required, but a record with nothing on it is a record nobody can
search. Gather what the recruiter actually has: email, phone, current role and employer, skills,
location, current salary, expectation, notice period, LinkedIn, source.

**Do not invent anything.** If a field was not given, leave it out — never guess an employer from an
email domain, never estimate a salary, never infer a location from a phone number. An empty field is
recoverable; a wrong one gets believed.

**Preview, then confirm.** Call `create_candidate` without `confirm`, show exactly what will be
created, get an explicit yes, then `confirm: true`.

The tool checks for an existing candidate with the same email or name and refuses rather than
creating a duplicate. If it refuses, do not work around it by altering the name — surface the
existing record and ask whether they meant to update it, which is `/editcandidate`.

If the recruiter is pasting a CV, pull the facts out of it but still show them the parsed fields
before writing. CV parsing gets employers and dates wrong often enough that it is worth their eye.

Candidate details are PII: internal only, never client-facing, no bulk export.
