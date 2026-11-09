-- 0156_bhavesh_team_view.sql
-- 09/11/2026: give Bhavesh Patel (RecruitCRM user 65639) the admin/manager commands, the same way
-- Dale got them in 0088: can_view_usage, which is also the team-view (sees_team) flag. He gets the
-- team usage views (/usage, /team, /map, /adoption, /habits, /coach, /health), the whole-team
-- dashboard breakdown, /exceptions, other people's queues, schedules, calls and visits, /eow,
-- Push & Tell for any job, and /handover. He keeps his own desk and attention list.
--
-- Deliberately NOT is_admin: that would swap his dashboard to the firm view and drop his desk
-- (0037), and adds /tokens (revoke anyone) and webhook subscriptions.
--
-- Every active token, including OAuth session rows (0038 carries the flag through re-auth).

update public.mcp_tokens set can_view_usage = true where consultant_recruitcrm_id = 65639 and active;
