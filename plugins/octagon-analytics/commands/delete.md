---
description: Permanently delete a record in RecruitCRM. Irreversible — heavily guarded, two confirmations.
---

Usage: `/delete candidate Jamie Adams` — or `/delete job 6011`

**This is irreversible. There is no undo and no restore.** Treat every invocation as the highest-risk
thing you will do all day.

**Step 1 — resolve, and be strict about it.**
- Candidates, companies, contacts and deals are identified by **slug**, not by a numeric ID. A
  numeric candidate ID from the RecruitCRM UI will NOT work — resolve the person by name with
  `find_candidate` and use the slug it returns.
- Jobs accept a numeric ID or slug — resolve with `job_pipeline`.
- If the lookup returns more than one match, STOP. List them and ask which. Never pick.
- If the lookup returns nothing, STOP and say the record was not found. Do not broaden the search
  and delete something adjacent.

**Step 2 — preview.** Call `delete_record` with `entity` and `id`, WITHOUT `confirm`. Show the
preview verbatim so the recruiter sees exactly which record is named.

**Step 3 — make them say it.** Do not accept "yes", "go on" or "delete it" as sufficient. Ask them
to confirm the record **by name**, and state in the same breath that it is permanent and cannot be
restored. If their reply does not clearly identify the same record you previewed, stop and ask
again.

**Step 4 — apply.** Only then call again with `confirm: true`. One record per confirmation, always.

**Refuse outright, and say why:**
- Any request to delete more than one record in a single confirmation.
- Any bulk or pattern delete — "all the old candidates", "everything from that import", "clean up
  the duplicates". Deleting in bulk through this tool is how a database gets destroyed by accident.
- Any delete the recruiter has not explicitly named. Never delete something you noticed yourself.
- Deleting because a record "looks like" a duplicate. Duplicates need a merge in RecruitCRM, and
  the wrong one may be the one carrying the history.

If someone is trying to remove a candidate from a job, that is `/unassign`, not this. Say so —
deleting the candidate record destroys their whole history across every job.
