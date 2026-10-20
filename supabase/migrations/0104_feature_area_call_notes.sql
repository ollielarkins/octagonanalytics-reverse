-- 0104_feature_area_call_notes.sql
-- call_notes (octagon-mcp 3.70.0) reads one person's call notes / Devyce AI summaries live from
-- RecruitCRM: count it under 'lookup' in /map, beside notes_read. Otherwise identical to 0101.
create or replace function public.feature_area(p_tool text)
returns text language sql immutable as $function$
  select case
    when p_tool = '_session' then null
    when p_tool like 'content:%' or p_tool like 'prompt:%' or p_tool = 'cv_pack' then 'content'
    when p_tool in ('get_dashboard','weekly_kpis','billing','my_day') then 'dashboard'
    when p_tool in ('stalled_report','cold_jobs','awaiting_feedback_report','interview_requests_unbooked') then 'chasing'
    when p_tool = 'match_candidates' then 'matching'
    when p_tool in ('find_candidate','candidate_profile','job_pipeline','job_spec','notes_read','call_notes','files_list','pitch_history','reference_list','off_limit') then 'lookup'
    when p_tool in ('update_hiring_stage','assign_candidate','add_note','create_candidate','update_candidate','create_job','update_job','job_dpe',
                    'create_deal','update_deal','manage_client','manage_assignment','log_activity','hotlist','pitch_candidate','delete_record') then 'changes'
    when p_tool in ('send_email','push_tell','eow_email','dpe_email') then 'email'
    when p_tool in ('inbox','draft_reply') then 'inbox'
    when p_tool in ('usage_report','manage_tokens','platform_health','webhook_subscriptions','post_digest','team_insights') then 'admin'
    else 'reporting' end
$function$;
