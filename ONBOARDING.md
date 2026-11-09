# Admin and developer onboarding

For an admin rolling Octagon Analytics out, or a developer about to change it: what to set up, in what order, and where the rules live.

*Last reviewed 04/11/2026.*

> [!NOTE]
> **Recruiters:** your guide is the knowledge base's
> [Onboarding](https://docs.octagongroup.co.uk/use/getting-started/) page
> (getting connected, what to trust, your first week). This file does not repeat it.

## What you are setting up

Octagon Analytics is a Claude connector (`octagon-mcp`, a Supabase edge function) that reads a live
mirror of RecruitCRM and writes back to RecruitCRM with a preview and confirm on every change.
Recruiters reach it from claude.ai (chat or Cowork); the slash commands come from four plugins in the
[octagon-plugins](https://github.com/ollielarkins/octagon-plugins) marketplace. The Octagon Coach
arrives in Slack. See the [README](README.md) for the picture.

---

## Rolling it out (admin)

Do these once, in the claude.ai Team admin console.

1. **Connector, org-wide.** Admin settings → Connectors → add a custom connector named
   `Octagon Analytics` with URL
   `https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp`, available to the whole
   organisation. Each person then enables it and signs in on the Octagon login page with their own
   token (OAuth; the login page is `web/octagon-connect.html`).
2. **Org instructions.** Paste the block from [`rollout/org-instructions.md`](rollout/org-instructions.md)
   into the org-level instructions, so every chat knows the house rules (formats, attribution, the
   confirm gate, PII).
3. **Plugins.** Register the octagon-plugins marketplace; its `ADMIN-SETUP.md` covers publishing and
   who gets which plugin:

   | Plugin | Who gets it |
   |---|---|
   | `octagon-dashboard`, `octagon-reporting` | Everyone |
   | `octagon-actions` | Only people who should change RecruitCRM |
   | `octagon-admin` | Managers and admins |

   The connector also enforces this: write tools need `can_write` on the token, and admin tools
   refuse anyone without admin (or, for the usage views, usage-viewer) rights.
4. **Tokens.** Mint one per person (SQL in the [README](README.md#operating-it) and the
   [Runbook](https://docs.octagongroup.co.uk/run/runbook/)).
   The token maps to the person's RecruitCRM user, so their desk is scoped to them and their changes
   are attributed to them in RecruitCRM. Set `can_write`, `is_admin` and `can_view_usage` (team usage
   views without full admin) deliberately. Hand the plaintext over once; only its hash is stored.
5. **Slack.** The Coach DMs go only to the people in `app_settings.coach_pilot`; the Coach stays in shadow mode (previews to
   the admin) while `coach_shadow` is true. Details in the Runbook's Slack section.

After that, `/usage` shows who has connected and who never started, `/tokens` who holds access, and
`/health` whether sync and the scheduled jobs are healthy. Leavers lose access automatically when
RecruitCRM marks them inactive.

---

## Getting ready to change it (developer)

1. **Read the rules first:** [CONTRIBUTING.md](CONTRIBUTING.md) (migrations, deploys, commit
   habits, data safety) and [SECURITY.md](SECURITY.md). Then skim
   [`docs/DECISIONS.md`](docs/DECISIONS.md) for why things are the way they are.
2. **Tools:** git, Node 22+ (for the type check and the repo scripts). Clone both repos:
   this one and `octagon-plugins` (pull it before auditing commands; a stale copy has misled a
   review before).
3. **Supabase access:** you need a member account on project `kzcmssldvtjnbwwunuwm`.
   Sign the CLI in with that account (`npx supabase login`) and check `npx supabase projects list`
   shows the project: signed in to another account, everything returns 403. Functions deploy with
   the CLI; migrations go through the Supabase MCP `apply_migration` tool in Claude Code (with
   read-only `execute_sql` for checks). Never `db push`.
4. **Your own connector token**, minted as above, to test tools as a real user. To use the connector
   from Claude Code:

   ```bash
   claude mcp add --transport http octagon-analytics \
     https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp \
     --header "Authorization: Bearer $OCTAGON_MCP_TOKEN"
   ```

   Keep the token in an environment variable, never in a file in the repo.
5. **Slack:** join #troubleshooting, the issue log. Post `Issue: …` or `Feature: …`; when it ships,
   reply in its thread with the fix and add ✅.

> [!CAUTION]
> This repository is **public**. Never commit firm revenue or billing figures, candidate or
> client-contact names, emails, phone numbers, tokens or keys, including in test fixtures, SQL
> comments and commit messages.

## Where things are

| Need | Go to |
|---|---|
| Repo layout, deploy steps, secrets | [README](README.md) |
| Day-to-day operation, backfills, incidents | [Operations Runbook](https://docs.octagongroup.co.uk/run/runbook/) |
| How the parts connect | [Architecture](https://docs.octagongroup.co.uk/run/architecture/) |
| Every tool and command | [Tools Reference](https://docs.octagongroup.co.uk/run/tools/), [Commands](https://docs.octagongroup.co.uk/use/commands/) |
| What each number means | [Metrics and Definitions](https://docs.octagongroup.co.uk/use/metrics/) |
| What is done and open | [ROADMAP.MD](ROADMAP.MD) |

**Related:** [README](README.md) · [CONTRIBUTING.md](CONTRIBUTING.md) · [Getting started](https://docs.octagongroup.co.uk/use/getting-started/) · [Operations Runbook](https://docs.octagongroup.co.uk/run/runbook/)
