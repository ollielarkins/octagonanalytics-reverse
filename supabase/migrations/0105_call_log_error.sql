-- 0105_call_log_error.sql
-- octagon-mcp 3.70.1 records WHY a tool call failed: a short error code plus the HTTP status, e.g.
-- 'recruitcrm_error 429'. On 21/10/2026 assign_candidate failed 28 times (Will 3, Keelan 25) and
-- mcp_call_log held only ok=false, so the cause could not be found. Free-text errors are stored as
-- 'message', never their text (they can name a candidate); tool arguments are never stored.
alter table public.mcp_call_log add column if not exists error text;
comment on column public.mcp_call_log.error is 'Failed calls only: snake_case error code + HTTP status. Never arguments or record text.';
