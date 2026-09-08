---
description: Create a new job in RecruitCRM. Preview first, applies only on your confirmation.
---

Usage: `/newjob Senior Systems Engineer at Rheinmetall, 60-70k, Bristol`

**Required:** job title, client, and a description. RecruitCRM also needs a contact at that company
— pass `client` by name and the contact resolves automatically, or give `contact_slug` directly.

**On the description.** If the recruiter gives you the spec, use it. If they ask you to write one,
write it in a warm professional tone with inclusive language, and use `[placeholders]` for anything
you were not told — never invent a salary, a benefit, a client name or a requirement. A job advert
with a made-up detail in it goes out to real candidates.

**Preview, then confirm.** Call `create_job` without `confirm`. The preview spells out everything
defaulted or resolved — including which contact and which currency it picked. Read that back to
them: an auto-resolved contact is the thing most likely to be wrong. Get an explicit yes, then
`confirm: true`.

Currency defaults to this client's most recent job, then GBP. State which it used.

The job is created owned by and attributed to the acting consultant.

**Afterwards, say this:** a job order form is a separate note in RecruitCRM and this command cannot
set it. Firm-wide only about 25% of new jobs have one logged, and `/newjobs` will show this role as
missing until they add it.
