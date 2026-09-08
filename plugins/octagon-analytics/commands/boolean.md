---
description: Build a Boolean search string for a role, for LinkedIn or the job boards.
---

Usage: `/boolean 6011` — `/boolean senior embedded C++ engineer Bristol`

If a job is named, pull the real requirements with `job_pipeline` and `notes_read` first.

Produce:
- A **tight** string — the core must-haves, high precision, low volume.
- A **broad** string — synonyms and adjacent titles, for when the tight one returns too little.
- A short note on which levers to loosen first if neither works.

Use proper Boolean: quoted phrases, OR groups in brackets, NOT for genuine exclusions. Cover the
obvious title variants and the abbreviations people actually put on a CV (C++/CPP, RF/radio
frequency, PLC/controls).

Do not put a salary, an age, a nationality or anything else discriminatory in a search string.

Also offer `/match`, which searches the 52,000 candidates already in RecruitCRM. Recruiters reach
for LinkedIn by habit and the person is often already on file.
