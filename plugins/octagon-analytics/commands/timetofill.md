---
description: Time to fill in days — job created to first placement, firm and per consultant.
---

Usage: `/timetofill` — `/timetofill this year`

Call `time_to_fill`. Defaults to 2026 YTD; pass `from`, `to`, `consultant` or `team`.
State the window as DD/MM/YYYY.

Present: firm average, median, min and max in days, then the per-consultant breakdown.

**Median over mean.** One role that sat open for two years distorts an average badly. Lead with the
median and give the mean beside it if useful.

Two limits to state:
- It measures **job created → first placement**, so a role re-opened or re-used inflates the number
  through no fault of anyone working it.
- It only counts jobs that were **filled**. Roles that never placed are invisible here, so this is
  not a measure of overall success — a desk that fills the easy ones fast and abandons the hard ones
  looks excellent on this metric.

Owner-attributed: whose desk the role sat on, not who did the placing.
