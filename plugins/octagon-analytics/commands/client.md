---
description: Create or edit a company or a contact in RecruitCRM.
---

Usage: `/client new company Rheinmetall` — `/client new contact Sarah Kelly at Rheinmetall`
— `/client edit Rheinmetall website rheinmetall.com`

Calls `manage_client`. `kind` is `company` or `contact`. Omit `id` to create; pass it (a slug, or the
company name) to edit.

**A contact must carry a `client`** so it attaches to the right company. A contact created without
one floats unattached and will not resolve when someone later creates a job against that client.

**Do not invent company details.** No guessed websites, no assumed head-office cities, no inferred
industry. If it was not given, leave it blank.

**Preview, then confirm.** Call without `confirm`, show what will be created or changed, get an
explicit yes, then `confirm: true`. The tool checks for an existing record before creating — if it
finds one, surface it and ask whether they meant to edit rather than forcing a second record.

Worth knowing: company **status** (Prospect, Engaged, Client, Passive, Blocklisted, Do-not-contact)
drives `/bd`, and this command does not set it — that is a custom field in RecruitCRM. If they are
creating a prospect, say the status has to be set there or it will not appear in the BD pipeline.
