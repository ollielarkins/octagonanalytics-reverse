# Security Policy

For anyone who finds a security problem in Octagon Analytics, or needs to know how the platform protects the firm's data: how to report it, and the current security model.

*Last reviewed 04/11/2026.*

## Reporting a vulnerability

**Do not open a public GitHub issue**, and do not include candidate data, firm figures or working
exploit details in any public place. This repository is public.

- **Octagon staff:** tell Oliver directly, then post a short `Issue: …` in Slack #troubleshooting
  without the exploit detail.
- **Anyone else:** contact the repository owner (`ollielarkins` on GitHub) privately.

Include what you found, where (function, tool or endpoint), and how to reproduce it. A confirmed
problem is fixed in a migration or function
release, and the fix is replied in the Slack issue thread. Only the live deployment is supported;
there are no released versions to patch.

> [!IMPORTANT]
> If a token or secret may have leaked, say so first: tokens can be revoked at once (`/tokens`), and
> function secrets rotated in Supabase.

## Security model

What protects the data today. Each point is checked against the code named.

| Control | What it does | Where |
|---|---|---|
| Per-user connector tokens | Every `octagon-mcp` call carries a personal token, stored only as a SHA-256 hash. The acting person is derived from the token server-side, never from a tool argument. `can_write`, `is_admin` and `can_view_usage` are per token | `mcp_tokens`; `octagon-mcp` |
| OAuth sign-in | Authorisation code flow with PKCE (S256). `redirect_uri` must be exactly a claude.ai or claude.com MCP callback, or `http://localhost` / `127.0.0.1` for local clients; anything else is refused | `oauthRedirectAllowed()` in `octagon-mcp` |
| Confirm gate | Every write is a preview, then a confirm. The preview stores a one-time `card_nonce` with the exact permitted arguments, the tool and the person; a confirm with no stored nonce, different arguments or an expired nonce is refused. Batch writes stop at 25 records | `mcp_card_previews` (0131), `mcp_card_confirms` (0103) |
| Delete guard | `delete_record` also needs the record's name typed back (`confirm_name`), checked on the server | `octagon-mcp` 3.87.0 |
| Audit and attribution | Every applied write is logged in `audit_log`, and sent to RecruitCRM with the person's own user id (`updated_by`) | `octagon-mcp` |
| Off-limit and opt-out | Anything that puts a candidate in front of a client or on a job, and email to a candidate, checks off-limit live in RecruitCRM and fails closed. Email never goes to an opted-out person | `octagon-mcp` 3.86.0 |
| Locked functions | `recruitcrm-sync`, `coach-dm`, `digest-email`, `inbox-sync` and `recruitcrm-probe` accept only the service-role key or an `x-octagon-cron` header equal to `CRON_SECRET` (constant-time compare, fails closed if unset). `pg_cron` sends it from Vault. The public anon key no longer opens them | `_shared/caller.ts`, `cron_headers()` (0132) |
| Slack endpoints | `coach-actions` and `slack-command` verify the Slack request signature (HMAC, constant-time compare, timestamps older than 5 minutes refused) with their own app's signing secret before doing anything | each function |
| Webhook | `recruitcrm-webhook` requires the shared `WEBHOOK_SECRET` | `recruitcrm-webhook` |
| Leaver auto-revoke | When RecruitCRM marks a consultant inactive or deleted, their tokens are switched off and their inbox stops being polled, with an audit row | trigger in 0136 |
| Inbox | Only the person's own mailbox can be connected; metadata is purged after 30 days | `octagon-mcp`, `inbox-retention` cron |
| No public figures | Since 03/11/2026 no unauthenticated endpoint serves firm figures: `dashboard` and `dashboard-data` return 410 with no data; `feedback` accepts submissions and returns none | `dashboard/`, `dashboard-data/`, `feedback/` |
| Database | RLS on every public table (41 of 41 at 04/11/2026); report RPCs revoked from `anon` and `authenticated`; `SECURITY DEFINER` helpers pin `search_path` | migrations, e.g. 0107 |
| Data residency | Supabase in `eu-west-1`. The contacts mirror holds no email or phone (0145) | project settings, 0145 |

`verify_jwt` is declared per function in `supabase/config.toml`, with the reason for each. Secrets
live in Supabase function secrets and Vault, never in the repo.

## Known gaps

Open as of 04/11/2026, tracked in [ROADMAP.MD](ROADMAP.MD):

- OAuth access tokens advertise a 90-day lifetime but never expire; they last until revoked.
- `update_deal` and `activity_report` do not check that the caller owns the record.
- The webhook secret travels in the callback URL (`?key=`), so it can appear in logs.
- 64 deals in the mirror have no RecruitCRM id.

**Related:** [README](README.md#security) · [CONTRIBUTING.md](CONTRIBUTING.md#data-safety) · [Architecture](https://octagon-kb.pages.dev/run/architecture/)
