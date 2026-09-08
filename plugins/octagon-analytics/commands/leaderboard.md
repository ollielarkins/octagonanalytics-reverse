---
description: Consultants ranked by placements, CV sends or first interviews for a window.
---

Usage: `/leaderboard` — `/leaderboard cv_sent this quarter`

Call `consultant_leaderboard`. `metric` is `placed` (default), `cv_sent` or `first_interview`.
Defaults to 2026 YTD; pass `from` and `to` to narrow. State the window as DD/MM/YYYY.

Present the ranking with CV sends, first interviews, placements and CV→placed rate to 1 dp.

Counts distinct candidate-job pairs, credited to whoever **moved** the stage — so it reflects who
did the work, not who owns the job.

Handle this one carefully. A leaderboard invites a judgement the data does not support:
- Desks are not comparable. Contract and permanent, new and established, hard and easy briefs all
  produce different numbers for reasons that have nothing to do with effort.
- Placements are lumpy. A quarter with one big placement and a quarter with four small ones can
  represent identical work.
- Volume at the top of the funnel is not quality. A high CV-send count with a low conversion rate
  is usually a problem, not a win.

Report the order. Do not editorialise about who is "best" or "worst", and do not rank people by
inference on any metric that was not asked for.
