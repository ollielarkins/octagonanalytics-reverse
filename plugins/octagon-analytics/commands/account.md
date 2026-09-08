---
description: Per-client activity — CVs sent, interviews, placements and conversion, ranked.
---

Usage: `/account Rheinmetall` — or `/account` for the busiest accounts

Call `client_report`. Pass `client` for one account (partial match), or omit for the whole book.
Defaults to 2026 YTD; pass `from` and `to` to narrow. State the window as DD/MM/YYYY.

Present, highest volume first: client, CVs sent, first interviews, placements, open jobs, total
jobs, CV→placed rate to 1 dp naming the ratio.

For a single account, also pull `notes_read` with that client so recent conversations are visible
alongside the numbers — the story is usually in the notes, not the counts.

Coverage note: this covers about **99.8%** of jobs. A handful with no company on the record are
omitted, so a firm total here will not exactly match a firm total elsewhere.

A low CV→placed rate on a big account is worth naming, but it has many innocent explanations — a
hard brief, a slow client, one bad role. Say what the number is and let the recruiter read it.
