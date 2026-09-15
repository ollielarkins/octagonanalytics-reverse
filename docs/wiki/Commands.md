# Commands

57 slash commands. Type `/` in Cowork or a chat to see them, or just ask in plain
English - every command is a shortcut for something you can phrase yourself.

> [!NOTE]
> Commands that change RecruitCRM are marked **write**. Every one previews first and applies
> only on your explicit confirmation. Nothing is written on the model's judgement alone.

## Your day

Start here. These are the ones worth using daily.

| Command | What it does |
|---|---|
| `/myday` | Your standup — what needs you today: aging offers, stalled candidates, cold roles |
| `/dayplan` | Your day, laid out on Octagon's standard structure with your real priorities slotted in |
| `/week` | Current week stats — actuals against weekly targets for every KPI, with the gap named |
| `/eod` | End-of-day stats — today's activity so far against where the week needs to be |
| `/chase` | What to chase right now, across your whole pipeline, in priority order |
| `/yesterday` | Yesterday's activity — CV sends, interview requests, interviews booked, call stats and placements, per consultant |

## Performance and billing

How a desk, a person or the firm is actually doing.

| Command | What it does |
|---|---|
| `/funnel` | The recruitment funnel and conversion ratios for any window, firm or per consultant |
| `/billing` | Quarter-to-date billing against target, with pipeline as the forward indicator |
| `/fees` | The money behind Won deals — total and median fee, fee percentage achieved, by consultant |
| `/placements` | Placements with the fee attached — what was placed and what it is worth |
| `/leaderboard` | Consultants ranked by placements, CV sends or first interviews for a window |
| `/timetofill` | Time to fill in days — job created to first placement, firm and per consultant |
| `/rejections` | Why candidates fall out — client rejections versus our own screening |
| `/account` | Per-client activity — CVs sent, interviews, placements and conversion, ranked |
| `/bd` | BD progress — yesterday's prospect activity plus the current account-status pipeline |
| `/noteskpi` | Notes KPIs — leads, internal interviews and job order forms logged, by consultant |
| `/visits` | Client visits and meetings logged in RecruitCRM — the only place visits are recorded |
| `/evening` | Evening calls — who was on the phone after 17:00, by hour, independent of call tagging |

## Roles and pipeline

What is live, what has gone quiet, what needs chasing.

| Command | What it does |
|---|---|
| `/pipeline` | Look up a job and see who is in play, with each candidate's current stage |
| `/coldjobs` | Open roles with no candidate activity in the last 7 days, oldest first |
| `/jobstatus` | Open roles by status — what is actually live, on hold, closed or cancelled |
| `/newjobs` | New jobs added, and which are missing a completed job order form |
| `/stalled` | What is slipping firm-wide — aging offers and stalled candidates on open roles |
| `/unbooked` | Interview requests that were never booked in — candidates waiting on a date |
| `/feedback` | Candidates interviewed with no feedback logged since — silence in the system |

## Candidates

Finding people and seeing what is recorded about them.

| Command | What it does |
|---|---|
| `/find` | Find a candidate — their slug, and every job they are on with the current stage |
| `/candidate` | The full picture on one candidate — work history, education, every job and stage |
| `/match` | Match candidates to a job description by skills. Off-limit candidates excluded automatically |
| `/notes` | Read the notes already recorded against a candidate, job, company or contact |
| `/files` | List the files attached to a candidate, job or company in RecruitCRM |
| `/pitches` | Pitch history — which candidates were pitched to which clients, and what happened |

## Writing content

Drafting. It never invents a salary or a fact - you get a [placeholder] instead.

| Command | What it does |
|---|---|
| `/advert` | Write a job advert from a role in RecruitCRM or from a brief you paste |
| `/boolean` | Build a Boolean search string for a role, for LinkedIn or the job boards |
| `/specpitch` | Write a speculative pitch putting a candidate to a client — anonymised by default |
| `/interviewprep` | Prep a candidate for an interview — the role, the client, and what to expect |

## Changing records

Every one is two-step: preview, then your explicit confirm.

| Command | What it does |
|---|---|
| `/move` **write** | Move a candidate to a new hiring stage on a job. Preview first, applies only on your confirmation |
| `/assign` **write** | Assign a candidate to a job. Preview first, applies only on your confirmation |
| `/unassign` **write** | Take a candidate off a job, or hide/show them on the client shortlist |
| `/note` **write** | Add a note to a candidate or a job. Preview first, applies only on your confirmation |
| `/newjob` **write** | Create a new job in RecruitCRM. Preview first, applies only on your confirmation |
| `/editjob` **write** | Edit a job — close it, put it on hold, change the salary range or title |
| `/newcandidate` **write** | Add a new candidate to RecruitCRM. Duplicate-checked, preview first |
| `/editcandidate` **write** | Edit an existing candidate record. Before/after preview, applies only on your confirmation |
| `/newdeal` **write** | Create a deal in RecruitCRM — how revenue enters the system |
| `/won` **write** | Mark a deal as Won and enter the value — this is how billing is recorded |
| `/client` **write** | Create or edit a company or a contact in RecruitCRM |
| `/meeting` **write** | Log a client visit or meeting in RecruitCRM. Client visits are a reported KPI |
| `/task` **write** | Set a task or reminder in RecruitCRM against a client, job or candidate |
| `/pitch` **write** | Record a speculative pitch — candidate pitched to a client contact. Off-limit checked first |
| `/hotlist` **write** | Shared talent pools — list, create, add or remove candidates |
| `/offlimit` **write** | Check, list, mark or release off-limit candidates — who must not be approached |
| `/email` **write** | Draft or send an email to a candidate or contact. Outward-facing — draft is the default |
| `/delete` **write** | Permanently delete a record in RecruitCRM. Irreversible — heavily guarded, two confirmations |
| `/digest` **write** | Post one of the Octagon digests to Slack on demand — the morning brief, the day end or the weekly |

## Dashboard and reference

| Command | What it does |
|---|---|
| `/dashboard` | Render a live Octagon recruitment dashboard inline. Use whenever the recruiter says "dashboard", "KPIs", "overview", or a scoped request in the quoted form such as dashboard "clients", dashboard "Keelan Riley", dashboard "cold jobs", or dashboard "billing this quarter". Pulls fresh data from the octagon-mcp connector and draws it through the visualize widget path instead of the native connector widget, so it renders reliably even when the native inline widget fails to mount |
| `/kpi` | Headline recruitment KPIs only — placements, open jobs, pipeline value and firm totals, concise |
| `/ref` | Reference data from RecruitCRM — the valid IDs behind stages, types and statuses |

## Things worth knowing

**`/myday` and `/dayplan` need a desk.** They scope to your own pipeline, so your token has to
map to a consultant record. Admin tokens have no desk and get "consultant not found" - that is
expected, not a fault. Pass a name (`/myday Keelan Riley`) to look at someone else's.

**Windows default to 2026 year to date**, end date exclusive. Most reporting commands take one -
`/funnel Q2`, `/billing last month`, `/leaderboard July`.

**BD and client call counts undercount badly.** They count only *categorised* Devyce calls, and
categorisation is currently around 9%. Read [Data Caveats](Data-Caveats#call-categorisation) before
drawing anything from `/week`, `/eod` or `/bd`.

**Closing a role or losing a deal asks why.** `/editjob` and `/won` offer a reason list when
the status goes to closed, cancelled, on hold, Lost or Declined. Optional - but it is the only way
"why do we lose" ever becomes answerable.

**`/delete` is permanent.** No undo, no restore, and it asks twice.

**`/digest` and `/email` are outward-facing.** A digest posts into a Slack channel other
people read; an email cannot be recalled, and will never go to someone who has opted out.

## Where they live

The commands are in the [octagon-plugins](https://github.com/ollielarkins/octagon-plugins) repo under
`plugins/octagon-dashboard/commands/` - **not** in this one. `plugins/octagon-analytics/` here
holds a pointer only. Two copies of a command drift, and the one that gets edited is never the one
that ships.

---

**See also:** [Tools Reference](Tools-Reference) for the connector tools behind these commands - [Onboarding](Onboarding) to get set up - [Data Caveats](Data-Caveats) before quoting any of it
