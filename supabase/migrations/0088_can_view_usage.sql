-- 0088_can_view_usage.sql
-- A permission between recruiter and admin: see the team-usage views (/usage, /team, /map,
-- /adoption, /habits, /coach, /health) without becoming an admin. Admin would also swap the
-- holder's dashboard to the firm view and drop their own desk and attention list (see 0037), and
-- give /tokens (revoke anyone's access). Asked for Dale Barnett on 13/10/2026: he still runs a desk.
--
-- Carried through the OAuth bridge like is_admin (0038), or re-authenticating would drop it.

alter table public.mcp_tokens  add column if not exists can_view_usage boolean not null default false;
alter table public.oauth_codes add column if not exists can_view_usage boolean not null default false;

-- Dale Barnett (RecruitCRM user 77604): every active token, including OAuth session rows.
update public.mcp_tokens set can_view_usage = true where consultant_recruitcrm_id = 77604 and active;
