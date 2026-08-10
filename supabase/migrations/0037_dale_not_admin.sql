-- 0037_dale_not_admin.sql
-- Remove Dale's managerial access. 0034 seeded is_admin = true for both Ollie (0, admin) and
-- Dale (77604, manager); Dale is now a normal recruiter for reporting purposes. He keeps can_write
-- (updating stages/notes is delivery, not management) but loses the whole-team view:
--   get_dashboard  - no team breakdown; he sees firm totals + his OWN weekly/billing scorecard
--   weekly_kpis    - filtered to his own row
--   billing        - filtered to his own row
-- Ollie's tokens (consultant_recruitcrm_id = 0) remain the only admin identities.
update public.mcp_tokens set is_admin = false where consultant_recruitcrm_id = 77604;
