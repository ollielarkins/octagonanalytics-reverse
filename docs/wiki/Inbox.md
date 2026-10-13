# Inbox

Each recruiter can connect their own @octagongroup.co.uk Outlook inbox. The platform checks it every
5 minutes, tells them in chat what has arrived, and on request saves a reply to their Outlook Drafts.
**It never sends email**: the Microsoft permission it holds can create drafts but not send.

## What a recruiter sees

- **At the start of each chat:** a line in the dashboard summary and "your day", e.g.
  *Inbox: 4 new since you last looked (2 routine, 1 to handle yourself, 1 other).*
- **"What's new in my inbox?"** lists emails since they last looked, newest first, each with a category:

  | Category | Means | Examples |
  |---|---|---|
  | routine | Safe to draft a reply for | scheduling, calendar responses, acknowledgements, admin |
  | never | The recruiter handles it personally; no draft is suggested | offers, salary or rates, fees and invoices, complaints, legal, any £ amount |
  | other | No rule matched | |
  | automated | Counted, never listed | out-of-office, bounces, no-reply senders |

  "Never" is checked before "routine", so "thanks, about the offer" is never-touch. The rules are
  deliberately broad, because a false "never" costs one manual reply and a false "routine" on an offer
  costs far more.
- **"Read the one from X"** fetches that email in full, live from Outlook.
- **Attachments** are listed when an email is read. "Read the attachment" opens one: PDFs and Word
  documents come back as text, images as images Claude can see, text and CSV files as text, up to
  10 MB. Other types (Excel, zip, attached emails) are listed but have to be opened in Outlook. Like
  bodies, attachments are fetched only on request and never stored.
- **"Draft a reply"** shows the reply in chat first. Only on confirmation is it saved to Outlook
  Drafts, in the same thread with the original quoted. The recruiter sends it from Outlook.

## Tools

| Tool | Does |
|---|---|
| `inbox` | `status` (default), `list`, `read`, `connect`, `disconnect`. Only ever the caller's own mailbox. |
| `draft_reply` | Preview, then `confirm=true` saves a reply draft. Needs a write-enabled token. |

## Data held

- **Stored:** sender name and address, subject, received time, thread id, read state, category and the
  rule that set it. Table `inbox_messages`, purged after 30 days by the `inbox-retention` job.
- **Not stored:** bodies. The ~255-character preview Microsoft returns is used to classify and then
  dropped. A full email is fetched only when its owner asks to read it, and it is not saved.
- Every connect, disconnect and draft is written to `audit_log`.

## Opting in

A mailbox is checked only after its owner connects it: "connect my inbox" shows a preview and
connects on confirmation. The address comes from the recruiter's consultant record, the same
@octagongroup.co.uk address as in RecruitCRM. Admin tokens have no consultant record, so they give
the address explicitly. All admin tokens share one connection (consultant id 0).

"Disconnect my inbox" stops the checks and deletes the stored details.

---

## Setup (Microsoft 365 admin, once)

### 1. Register the app

1. In the Entra admin centre, go to **App registrations → New registration**. Name it `Octagon Inbox`,
   choose single tenant, and leave the redirect URI empty.
2. Under **API permissions → Add a permission → Microsoft Graph → Application permissions**, add
   **Mail.ReadWrite**, then **Grant admin consent**. Don't add Mail.Send.
3. Under **Certificates & secrets → New client secret**, create a secret and copy its **Value**.
4. From the Overview page, note the **Application (client) ID** and the **Directory (tenant) ID**.

### 2. Restrict it to the people who use it

Granted on its own, Mail.ReadWrite reaches every mailbox in the tenant. Scope it to a group:

1. Create a **mail-enabled security group**, e.g. `octagon-inbox@octagongroup.co.uk`, and add the
   recruiters who will connect their inbox.
2. In Exchange Online PowerShell:
   ```powershell
   Connect-ExchangeOnline
   New-ApplicationAccessPolicy -AppId <client-id> -PolicyScopeGroupId octagon-inbox@octagongroup.co.uk `
     -AccessRight RestrictAccess -Description "Octagon platform: inbox check and reply drafts"
   Test-ApplicationAccessPolicy -Identity olarkins@octagongroup.co.uk -AppId <client-id>   # expect Granted
   ```
   Changes can take up to an hour to apply.

Microsoft now steers new set-ups towards **RBAC for Applications** in Exchange Online instead of
application access policies. If you use that route, assign the `Application Mail.ReadWrite` role
scoped to the group, and **remove** the Entra grant from step 1.2. Entra-granted permissions are not
scoped, and they add to the RBAC grant rather than being limited by it.

### 3. Give the platform the credentials

Run this locally. Never paste the secret into chat:
```bash
npx supabase secrets set MS_TENANT_ID=<tenant-id> MS_CLIENT_ID=<client-id> MS_CLIENT_SECRET=<secret> \
  --project-ref kzcmssldvtjnbwwunuwm
```
Until these are set, `inbox-sync` records `not_configured` and checks nothing.

### 4. Deploy, in this order

1. Migration `0085_inbox.sql`.
2. `npx supabase functions deploy inbox-sync --project-ref kzcmssldvtjnbwwunuwm --use-api`
3. `npx supabase functions deploy octagon-mcp --project-ref kzcmssldvtjnbwwunuwm --use-api`

Then, in chat: "connect my inbox".

### 5. Once it is running

Add `('inbox','live',15,45,false)` to the `cfg` list in `sync_health()` so a stalled check alerts. It is
left out of 0085 because every run reports `not_configured` until step 3, which would alert.

## Renewing the secret

Client secrets expire. Before expiry, create a new one, run step 3 again with the new value, and delete
the old secret in Entra. An expired secret shows as `error graph_auth_failed` in the "your day" line
and in `inbox_mailboxes.last_status`.
