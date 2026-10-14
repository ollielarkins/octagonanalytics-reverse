-- push_tell (octagon-mcp 3.56.0) drafts the weekly client email, so /map counts it under 'email'.
-- Otherwise identical to 0091.
create or replace function public.feature_area(p_tool text)
returns text language sql immutable as $function$
  select case
    when p_tool = '_session' then null
    when p_tool like 'content:%' or p_tool like 'prompt:%' then 'content'
    when p_tool in ('get_dashboard','weekly_kpis','billing','my_day') then 'dashboard'
    when p_tool in ('stalled_report','cold_jobs','awaiting_feedback_report','interview_requests_unbooked') then 'chasing'
    when p_tool = 'match_candidates' then 'matching'
    when p_tool in ('find_candidate','candidate_profile','job_pipeline','notes_read','files_list','pitch_history','reference_list','off_limit') then 'lookup'
    when p_tool in ('update_hiring_stage','assign_candidate','add_note','create_candidate','update_candidate','create_job','update_job','job_dpe',
                    'create_deal','update_deal','manage_client','manage_assignment','log_activity','hotlist','pitch_candidate','delete_record') then 'changes'
    when p_tool in ('send_email','push_tell') then 'email'
    when p_tool in ('inbox','draft_reply') then 'inbox'
    when p_tool in ('usage_report','manage_tokens','platform_health','webhook_subscriptions','post_digest','team_insights') then 'admin'
    else 'reporting' end
$function$;
