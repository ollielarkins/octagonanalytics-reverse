-- 0034_token_is_admin.sql
-- Role flag on access tokens so the dashboard can scope per-recruiter KPIs/targets: admins/managers
-- see the whole-team breakdown; regular recruiters see firm totals + only their OWN scorecard.
alter table public.mcp_tokens add column if not exists is_admin boolean not null default false;
update public.mcp_tokens set is_admin = true where consultant_recruitcrm_id in (0, 77604); -- Ollie (admin), Dale (manager)
