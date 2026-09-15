# Onboarding — start to finish

For a recruiter joining Octagon Analytics. Fifteen minutes to set up, then a first week that builds
from "look at my desk" to "run my day from it".

---

## Part 1 — Get connected

### Step 1. Get your access token

Ask Ollie to mint you one. It maps to **you**: your figures are scoped to your desk, and anything
you change in RecruitCRM is attributed to your name, not to a shared service account.

Treat it like a password. Don't paste it into chats, tickets or shared docs.

Two things are set on your token when it's created:

- **Write access** — whether you can change anything in RecruitCRM at all. Everyone currently holding
  a token has it.
- **Admin** — whether you see the whole team or just your own desk. Recruiters see their own.

### Step 2. Add the connector

**claude.ai (web or desktop):**

1. Settings → Connectors → Add custom connector
2. Name: `Octagon Analytics`
3. URL: `https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp`
4. When prompted to authenticate, paste your Octagon token into the login page
5. Save and enable

If the connector has already been pushed out org-wide, you may only need to enable it and sign in.

**Claude Code:** set your token as an environment variable and restart, then install the plugin:

```powershell
[Environment]::SetEnvironmentVariable('OCTAGON_MCP_TOKEN','<your token>','User')
```

If the connector's tools are missing or every call returns an authentication error, that variable is
unset or holds a revoked token. Tokens were rotated on 15/09/2026 — anything issued before that date
is dead.

### Step 3. Check it worked

Start a new chat and ask:

> show me my dashboard

You should get **Your desk — <your name>** with your own numbers. If you see "Octagon Recruitment
Dashboard" with a whole-team table instead, your token is resolving as an admin — tell Ollie.

If you get an authentication error, your token is wrong or revoked. If nothing happens at all, the
connector isn't enabled in that chat.

---

## Part 2 — Read this before you trust a number

Three things will look broken on day one and aren't. Knowing them up front saves you raising them as
bugs — and saves you drawing the wrong conclusion.

**Your BD and client call counts will look too low.** They only count Devyce calls that have been
*categorised*. Firm-wide only about a quarter of calls are tagged. Your dashboard shows your own
tagging rate right underneath, so you can see whether a red number means "call more" or "tag your
calls". Usually it's the second one.

**On Monday morning everything reads 0.** The KPI week runs Monday to Sunday. A fresh week genuinely
is 0/10 CV sends. Come back Wednesday.

**Shortlist looks odd.** The stage is only used by some of the desk, so there are fewer shortlist
events than CV sends. Don't read it as the top of your funnel.

Full list on the **[Data Caveats](Data-Caveats)** page. Worth five minutes before you quote anything
to a client.

---

## Part 3 — Your first week

### Day 1 — your desk

> show me my dashboard

You get, in order: your headline cards, your week against target, your quarterly billing against
target, then the part that actually matters — **aging offers** and **stalled candidates**, most
overdue first, followed by your 2026 funnel.

The attention list is the point. It's every candidate on your open roles who has gone quiet: offers
out 5–60 days with no response, and candidates sitting at an active stage with no movement for
10–60 days. It deliberately excludes anything older than 60 days, because that's abandoned rather
than stalled.

Then:

> what's my day?

Same data, action-ordered.

### Day 2 — your numbers

> how am I doing this week?
> what's my billing this quarter?
> which of my roles have gone cold?

Cold means an open role with no candidate activity for 14 days.

### Day 3 — a live role

> what's happening on the <job title> role?
> who have we got in play for <client>?

### Day 4 — content

Paste a job spec and ask for what you need:

> write me the LinkedIn advert and the website advert for this
> build me Boolean strings for job boards and LinkedIn
> write a client pitch I can use on the phone
> find me the top 5 candidates on the CRM for this

It won't invent a salary — you'll get a `[placeholder]` if you didn't give it one. That's deliberate.

### Day 5 — the whole vacancy

> new job kickoff for <job title>

Runs Octagon's vacancy checklist end to end: research and pitch, a top-5 CRM shortlist with reasons,
then adverts, Boolean and InMail on request.

---

## Part 4 — Making changes (write access)

Only if write access is enabled on your token.

Every change is **two-step**. You ask, it shows you exactly what will change, you confirm, and only
then does it touch RecruitCRM. Nothing is written on the strength of the model's judgement alone.

> move <candidate> to 1st interview on the <job> role

You'll get a preview: current stage, proposed stage, which job. Say yes and it applies, writes an
audit record, and refreshes the mirror immediately so your dashboard is right straight away.

Far more than three things: hiring stages, assigning and unassigning candidates, notes, jobs, deals,
candidates, companies, contacts, pitches, meetings, tasks, hotlists, off-limit flags, email and
deletions. All attributed to you.

**Closing a job or losing a deal asks you why.** Pick from the list it offers — "Filled by client
directly", "Counter-offer accepted", "Budget pulled" and so on — or add your own detail. It is
optional and you can skip it, but it is the only way "why do we lose" ever becomes answerable. Any
other deal stage move takes a free-text note instead.

Two writes are different and are guarded harder. **Deletion is permanent** — there is no undo and no
restore, and it asks twice. **Email cannot be recalled**, so drafting is the default and it will
never send to someone who has opted out.

> **Status:** 44 writes have been made through this system, the first on 12/08/2026 — mostly hiring
> stage moves. Every one is in `audit_log` with who did it and what changed.

---

## Part 5 — Getting good at it

**Ask in plain English.** "How did I do in Q2 compared to Q1" works. You don't need command syntax.

**Slash commands exist for the common things** — type `/` to see all 57. The ones worth learning
first: `/myday`, `/dayplan`, `/week`, `/billing`, `/chase`, `/pipeline`, `/coldjobs`, `/funnel`.

`/myday` and `/dayplan` scope to your own desk, so they need your token to map to a consultant
record. Admin tokens have no desk and will get "consultant not found" — that is expected, not a
fault.

**It will tell you when it can't answer.** If a number genuinely isn't in the data you'll get "that
isn't tracked" rather than a made-up figure. That's the system working.

**Leads, internal interviews, pitched candidates and client visits ARE reportable.** They were long
believed untrackable; they are not. Leads and internal interviews are note types, pitches are
RecruitCRM's pitch feature, client visits are meetings — all now readable. Just ask. Bear in mind
they count what was *logged*, so a lead nobody wrote a note about won't appear.

**Ask it to show its working.** "Where does that number come from?" gets you the definition.

---

## Something not working?

Ping Ollie on Slack with what you asked, what you expected and what you got. Screenshots help.
