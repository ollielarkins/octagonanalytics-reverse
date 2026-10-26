-- 0107_lock_down_report_rpcs.sql
-- Security advisor, 21/10/2026: five SECURITY DEFINER report functions were executable by the
-- `authenticated` role, so any signed-in Supabase user could call /rest/v1/rpc/<name> directly and
-- skip the connector's per-user token and desk scoping. Their only caller is octagon-mcp, which
-- uses the service role, so revoking costs nothing. Per CONTRIBUTING: revoke by default, grant back
-- only what a caller needs.
revoke execute on function public.awaiting_feedback_report(integer, integer, text) from public, anon, authenticated;
revoke execute on function public.call_hours_report(date, date, text, integer)     from public, anon, authenticated;
revoke execute on function public.interview_requests_unbooked(integer, text)        from public, anon, authenticated;
revoke execute on function public.new_jobs_report(date, date, text)                 from public, anon, authenticated;
revoke execute on function public.placements_with_fees(date, date, text)            from public, anon, authenticated;
grant execute on function public.awaiting_feedback_report(integer, integer, text) to service_role;
grant execute on function public.call_hours_report(date, date, text, integer)     to service_role;
grant execute on function public.interview_requests_unbooked(integer, text)        to service_role;
grant execute on function public.new_jobs_report(date, date, text)                 to service_role;
grant execute on function public.placements_with_fees(date, date, text)            to service_role;

-- Same advisor run: pin search_path on the plain helper functions (function_search_path_mutable).
alter function public.feature_area(text)   set search_path = public, pg_temp;
alter function public.slack_escape(text)   set search_path = public, pg_temp;
alter function public.slack_fields(jsonb)  set search_path = public, pg_temp;
alter function public.slack_section(text)  set search_path = public, pg_temp;
alter function public.slack_context(text)  set search_path = public, pg_temp;
