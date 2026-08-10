-- 0042_drop_daily_activity.sql
-- Remove daily_activity and its view. Nothing reads them and both of their jobs were taken by
-- something else, so keeping the table only risks someone treating it as a second funnel source.
--
-- Evidence for the removal (checked 10/08/2026):
--   * Never connected. M0 flagged "where daily_activity numbers come from" as a blocking open
--     question; it was never answered, so no ingestion path was ever built. The 1,839 rows are a
--     one-off import of unrecorded provenance (D1).
--   * Superseded twice over: candidate_stage_events is the canonical funnel source (D1/D4), and
--     call_activity (0027, Devyce) is the live activity/leading-indicator layer.
--   * Half the schema was never populated: lead, pitched, internal_interview,
--     job_order_form_complete, prospect_bd, client, call_time_minutes, jobs_added and assigned are
--     0 in every row across both 2025 and 2026.
--   * What is populated disagrees badly with the event stream — Jan 2026 shows 56 cv_sent against
--     256 in candidate_stage_events, tailing to 7 against 346 in July.
--   * Stale since 08/07/2026, absent from sync_state, and no MCP tool exposes it.
--
-- IRREVERSIBLE: this deletes 1,839 rows. Nothing in the codebase reads them and the figures are a
-- partial copy of data we hold properly elsewhere, but the rows themselves are not recoverable from
-- this migration.
--
-- If leads / pitched candidates / internal interviews are ever tracked again, build the capture
-- deliberately against a table that says where its numbers come from — don't revive this one.
drop view if exists public.daily_activity_summary;
drop view if exists public.reported_activity_daily;
drop table if exists public.daily_activity cascade;
