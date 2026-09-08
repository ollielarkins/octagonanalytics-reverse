---
description: Shared talent pools — list, create, add or remove candidates.
---

Usage: `/hotlist list` — `/hotlist create Bristol RF Engineers` — `/hotlist add Jamie Adams to 42`

Calls `hotlist`. Actions: `list` (read-only), `create`, `add`, `remove` (all writes).

`list` — show each hotlist with its id and whether it is shared. The id is what `add` and `remove`
need.

`create` — takes a `name` and `shared` (visible to the team). Ask whether it should be shared;
default to shared unless they say otherwise, since a private hotlist is barely different from a
note to yourself.

`add` / `remove` — take a `candidate` and a `hotlist_id`. Resolve the candidate with
`find_candidate` first, and if the hotlist was named rather than numbered, run `list` to get the id
rather than guessing.

**Preview, then confirm** for every write: call without `confirm`, show it verbatim, get an
explicit yes, then `confirm: true`.

This is the tool for turning a shortlist into something the team can see rather than a message in a
chat. If a recruiter is describing a group of candidates they keep coming back to, offer it.

Candidate names are PII: internal only.
