# Octagon Analytics — getting set up with Claude

This connects you to **live RecruitCRM analytics** inside Claude. You ask questions in plain English
(or use slash commands) and get answers that match the dashboards exactly, because both read the
same vetted metrics layer.

There are two ways to use it. Pick the one that matches how you use Claude.

---

## Step 0 — get your access token (everyone)

You need a personal **Octagon access token**. Ask an admin (Ollie) to mint one for you — it maps to
you, so your activity and any changes you make are attributed correctly. Read-only by default;
write access (moving hiring stages, adding notes) is granted per person.

Keep the token private — treat it like a password.

---

## Path A — claude.ai (the web/desktop app, Team plan)

1. Go to **Settings → Connectors → Add custom connector**.
2. Name it `Octagon Analytics` and set the URL to:
   `https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp`
3. When it asks for authentication, add a header **`Authorization`** with value **`Bearer <your token>`**
   (paste the token from Step 0).
4. Save and enable it. In a new chat, type `/` — you should see the Octagon commands.

> If the admin has already pushed this connector out org-wide, you may just need to **enable it** and
> paste your token — you won't have to add the URL by hand.

## Path B — Claude Code (the CLI / IDE extension)

1. Set your token as an environment variable, then launch Claude Code:

   **macOS / Linux**
   ```bash
   export OCTAGON_MCP_TOKEN="your-token-here"
   claude
   ```
   **Windows PowerShell**
   ```powershell
   $env:OCTAGON_MCP_TOKEN = "your-token-here"
   claude
   ```
   (To make it stick, add it to your shell profile / environment variables.)

2. Install the plugin from the team marketplace:
   ```
   /plugin marketplace add ollielarkins/octagonanalytics-reverse
   /plugin install octagon-analytics@octagon
   ```

That bundles the connector, the `/kpi` and `/dashboard` commands, and a session-start dashboard.

---

## Try it

- `/dashboard` — the full firm view
- `/kpi` — headline numbers only
- `/my_day` — what needs *your* attention today
- Or just ask: *"how did Keelan do in Q2"*, *"which of my roles have gone cold"*,
  *"our busiest accounts this year"*, *"who's making the most calls this week"*.

Performance is attributed to the **job owner**; date windows default to **2026 year-to-date**.

---

## The ground rules (please read)

- Candidate names and notes are **PII** — don't paste them into other tools or share them outside
  the firm, and don't ask for bulk exports of them.
- Reporting is **read-only**. The write actions (update hiring stage, assign candidate, add note)
  need a write-enabled token and **always show you a preview first** — check it, then confirm. Never
  approve a change you haven't read.
- If Claude says a question **can't** be answered from the data, trust that over a guessed number.

---

## For the admin/owner — org-wide rollout

Do these once, in the **claude.ai Team admin console**:

1. **Connector, org-wide.** Admin settings → Connectors → add the custom connector above, then set
   it **available to the whole organisation**. Teammates then only enable it + paste their own token.
2. **Org instructions.** Paste the block from [`rollout/org-instructions.md`](rollout/org-instructions.md)
   into the org-level custom instructions so every chat knows the commands and the guardrails.
3. **Plugin marketplace (Claude Code users).** The marketplace lives in this repo
   (`.claude-plugin/marketplace.json`). Share the two `/plugin` commands from Path B, or add the
   marketplace at project scope so it's shared automatically.
4. **Mint tokens.** Create one token per recruiter (read-only), and set `can_write` only for those
   who should be able to make changes.
