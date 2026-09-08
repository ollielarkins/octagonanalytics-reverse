---
description: The recruitment funnel and conversion ratios for any window, firm or per consultant.
---

Usage: `/funnel` — `/funnel Keelan Riley Q2` — `/funnel the tech team last month`

Call `funnel_report`. Defaults to 2026 YTD; pass `from`, `to`, `consultant` (partial name) or
`team`. `to` is exclusive. State the window as DD/MM/YYYY.

Present stages in order — **CV Sent → Interview Request → 1st → 2nd → 3rd → Offered → Placed** —
then the ratios, each named: CV→interview, CV→1st interview, 1st interview→offer, CV→placed. Rates
to 1 dp. Then the per-consultant table, highest CV sends first.

Counts distinct candidate-job pairs at the **last** time they entered each stage, credited to
whoever moved them.

**Accuracy, if anyone asks how far this can be trusted:** it is measured against RecruitCRM's own
lifecycle report across five periods. 34 of 50 stage-months are exact, and Offered, Placed, 2nd and
3rd Interview are exact in every month tested. Residual divergence is about 0.4% and sits in
Shortlist, CV Sent and Rejected — Consultant. The cause is RecruitCRM's report omitting rows its own
API returns, so the API is treated as the source of truth. Do not volunteer this every time — give
it when the number is being questioned or is going in front of the business.

Conversion ratios are the point, not the volumes. A desk sending 300 CVs at 1% is not outperforming
one sending 100 at 4%.
