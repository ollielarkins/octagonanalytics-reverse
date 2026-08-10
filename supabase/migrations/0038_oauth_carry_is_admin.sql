-- 0038_oauth_carry_is_admin.sql
-- The OAuth bridge minted session tokens without is_admin, so it defaulted to false: re-authenticating
-- the connector silently demoted an admin to the recruiter view (firm totals, no team breakdown).
-- Carry the flag through the exchange the same way can_write already is:
--   /authorize  reads is_admin off the pasted Octagon token -> stores it on the code
--   /token      copies it from the code onto the new mcp_tokens session row
alter table public.oauth_codes add column if not exists is_admin boolean not null default false;
