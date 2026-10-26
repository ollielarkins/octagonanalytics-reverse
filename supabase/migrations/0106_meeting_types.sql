-- 0106_meeting_types.sql
-- octagon-mcp 3.71.0: meeting_review lists a consultant's untyped RecruitCRM meetings with a
-- suggested type, so client visits can be counted against the minimum of 2 per quarter.
--
-- meeting_type_skips: meetings a consultant has marked "not a work meeting" (Outlook calendar
-- entries synced into RecruitCRM: personal appointments and the like), so they aren't asked again.
-- Holds the RecruitCRM meeting id and who skipped it, nothing else. Service role only.
create table if not exists public.meeting_type_skips (
  meeting_id bigint primary key,
  consultant_recruitcrm_id bigint,
  created_at timestamptz not null default now()
);
alter table public.meeting_type_skips enable row level security;
revoke all on public.meeting_type_skips from anon, authenticated;
comment on table public.meeting_type_skips is 'meeting_review: meetings marked not-a-work-meeting, so they are not asked about again. Ids only. Service role only.';

-- Count meeting_review under 'changes' in /map. Otherwise identical to 0104.
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
                    'create_deal','update_deal','manage_client','manage_assignment','log_activity','meeting_review','hotlist','pitch_candidate','delete_record') then 'changes'
    when p_tool in ('send_email','push_tell','eow_email','dpe_email') then 'email'
    when p_tool in ('inbox','draft_reply') then 'inbox'
    when p_tool in ('usage_report','manage_tokens','platform_health','webhook_subscriptions','post_digest','team_insights') then 'admin'
    else 'reporting' end
$function$;
